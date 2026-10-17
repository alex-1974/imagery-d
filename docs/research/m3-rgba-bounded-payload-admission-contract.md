# M3 RGBA — bounded requested-pixel payload admission contract

**2026-10-15 · Issue #74 · Draft PR #73 · research-only proposal,
mechanically tested, NOT an accepted public/API/resident-memory contract.**

**Disposition:** **ADAPT** the pre-existing narrow source-over,
move-only generation model into a *logical pixel-request quota*, but
**DEFER** an all-in physical resident-memory guarantee, production
promotion, PR merge and release.

## Why a narrower contract, not another generic RSS probe?

The [2026-10-15 native-C XPS study]
(m3-rgba-native-kernel-peak-c-xps-2026-10-15.md)
independently validates 48 native producer event traces and
per-owner pixel lifetimes, but the kernel's `wait4` RSS high-water
and in-child `/proc` observations disagree in **9/12**
full-production processes (signed discrepancy −128 to +116 KiB).
The original Python process-launch high-water artifact was separately
diagnosed and corrected. It would be unscientific to turn *either*
RSS reading, or interposed `malloc` requested-size peaks,
into an all-in process-memory ceiling.

The [four-arm native import GC control]
(m3-rgba-native-gc-range-control-xps-2026-10-15.md)
supports attribution of a **48/72/48/24 B request trajectory**
to druntime conservative GC-range bookkeeping on the pinned host.
The four-byte sizes are **allocation request events**, not a
fixed physical surcharge per raster generation.
The [40-process one/four-subscriber study]
(m3-rgba-generation-subscriber-physical-memory-xps-2026-10-15.md)
confirms that increasing real subscribers from **3 to 12**
does not create nine extra physical packed output backings
or increase the existing generation ledger's pixel credit.
Neither dataset provides a certified allocator-usable-byte or
GC-residency budget.

The **one scientifically supported capacity invariant** is the
number of requested bytes in the two explicitly owned RGBA pixel
buffers within the *fixed, serial, source-over producer protocol*.

## Concrete workload and non-goals

**Applicable input:** a validated, nonempty ROI on already
materialized, readable RGBA source fixtures; four bytes of
per-pixel scratch storage and four bytes of packed `SRgba8`
output, as implemented by the currently tested research
source-over/import path. No general image source, multi-precision
format, halo, encoded tile, lazy decoder or generic raster
scheduler is implied.

This is an **admission accounting contract** over the exact
*requested pixel-buffer bytes*, not allocator usage, resident
memory, an unconditional allocation success guarantee,
external input-fixture size, or the whole process.

**Not included:** input image/source storage, existing foreign
raster allocations, per-owner raster-d control records,
`malloc` headers/alignment/usable-size rounding, unrelated
native or mmap allocations, shared GC range registry, control
class's GC heap, caches outside the research generation ledger,
stack usage, thread resources, page retention, source decoding
and pixel-buffer allocations not owned by this specific
producer. These must not be silently charged as zero or
included in a claimed physical maximum.

## Checkable arithmetic and state transitions

For a valid ROI with `N = width × height`, define:

```text
scratch_requested(N)   = 4 * N
packed_requested(N)    = 4 * N
producer_peak(N)       = 8 * N   // two tagged buffers coexist
retained_output(N)     = 4 * N   // final packed RasterLease backing

P = sum(producer_peak(Nj) for RESERVED in-flight generations j)
  + sum(retained_output(Ni) for PUBLISHED generations i)
```

A generation is counted **once**, by identity, not by cache slot
or number of subscribers. Its reservation is either RESERVED
(8N) or PUBLISHED (4N), **never both**.

For every *new* producer of ROI size `N`, only reserve if:

```text
N > 0 and all region/stride/size calculations checked
P <= capacity
producer_peak(N) <= capacity - P
a free generation ticket exists
the target cache slot accepts a pending reservation
```

Reject **before** allocating the new scratch or packed pixels.
The checked subtraction form prevents `P + producer_peak`
unsigned overflow. A valid failure leaves `P`, generation
records, cache slots and output ownership unchanged and the
out-identifier inert.

- **reserve:** atomically in this serialized consumer, add
  `8N` credit *before* the first new producer buffer is allocated;
  no second reservation of that pending cache slot.
- **abort / error:** immediately discard the pending
  `8N` credit; return no published output. The producer's
  existing `scope(exit)` does this on every post-reservation
  failure. No claimed cancellation race or threaded guarantee.
- **publish success:** after the real RGBA producer and
  raster-d import succeed, replace `8N` with `4N`,
  releasing only the **transient** `4N` of credit. The output
  must have a genuine physical packed raster-d lease.
- **cache eviction:** dropping a cache's own raster lease
  does **not** return `4N` if any independent delivery
  subscriber retains that generation's backing.
- **retain / subscriber close:** additional real
  `RasterLease` subscriptions change participant count
  but never multiply the single backing's `4N` pixel credit.
  Closing the penultimate owner cannot refund it.
- **last physical owner:** release `4N` only when the
  *last* genuine backing owner retires and there is no
  live cache holder, then recycle the generation record.
  An evicted former generation still consumes credit while held.
- **cache scope teardown:** abort pending reservations and
  release cache-held leases; externally held generations and
  their `4N` charges remain alive after cache destruction.
- **unsupported external ownership / concurrency:** if the
  ledger cannot guarantee every external physical lease has
  a corresponding accounted participant, or if callbacks
  can race on the pinned `raster-d` non-atomic refcount,
  **this research policy is not admissible** as a hard contract.

### Overflow and capacity are distinct failures

The existing `tryPlanOwnedRgbaPayload` checks empty/overflowing
regions, byte-row-stride representability in `ptrdiff_t`,
`width*height`, `8*N`, and available logical payload bytes.
It returns an inert output on failure. The generation ledger
re-verifies the scalar relationships, rejecting hand-forged
cheap or overflowing plans. `GenerationAccounting.reserve`
also requires a free record, an empty target slot and checked
remaining capacity.

**Do not label an early refusal as malloc OOM.** An accepted
logical reservation may still fail its actual allocation or
import. Its failure path must release exactly its reservation
without publishing a partially owned result. A literal
kernel OOM/process termination is not catchable by this
in-process research ledger and is outside this promise.

## Independent numerical boundary (real production path)

For `16×16`, `N = 256`: scratch **1,024 B**,
packed **1,024 B**, producer peak **2,048 B**.
With an evicted old A generation that remains held by
real external subscribers, A costs **1,024 B** of the
logical pixel quota. Producing B while A remains held
requires **1,024 + 2,048 = 3,072 B**.

| Quota | Existing A | B admission | Expected accounting |
|---:|---|---|---|
| 3,071 B | A is held by two real subscribers | **refuse** before B materialization | Old A remains 1,024 B; no B identity |
| 3,072 B | A remains held | **accept** B materialization | After publish A+B = 2,048 B |
| 3,071 B | A's last owner has closed | **accept** B materialization | B = 1,024 B, then 0 B after eviction |
| 2,048 B | Empty cache; injected producer failure | **abort**, zero output | Entire temporary 2,048 B credit refunded; next success admissible |

The **existing research consumer** now tests all four cases
with real source-over and genuine `RasterLease` outputs in
`checkIndependentRasterGenerations()`. A new optional pair
`peakMetadata=0, retainedMetadata=0` makes the *payload-only*
test distinct from the historical **128/64 B illustrative
metadata quota** tests. In Debug **and Release**, CI requires
the explicit `M3 RGBA payload-only admission PASS:` marker.
All earlier tests of the illustrative 128/64 B ledger remain
unchanged; their arithmetic is correct *as an example*, but
not a certified physical overhead policy.

At this report's initial authoring time, the new exact
boundary still requires successful compiler/CI requalification
at its committing source SHA. Do not report a PASS until
those workflows complete.

## Two admission tiers — do not mix them

**Tier P — exact requested-pixel quota (this experiment):**
admit or refuse a bounded, serial RGBA producer solely on
the checked requested `4N / 8N` pixel obligations;
hold a credit for each *distinct physical generation*.
A cap here is reproducible, externally testable **and
does not promise physical RSS**.

**Tier R — physical process memory / overall resident budget:
NOT ESTABLISHED.** The allocator and GC may allocate
more bytes than requested and retain pages after the last
owner closes; input fixtures and other process resources
are separately resident. A fixed `+64`, `+128`,
`+152`, `+224`, `+256`, or arbitrary percentage
must **not** be advertised as a physically proved
per-generation margin. A consumer may configure a
platform-operational headroom reserve or an external
process limit, but such a policy must be identified
as **heuristic / platform-scoped** and cannot silently
become a library-wide exact memory guarantee.

If M3's future consumer actually requires a **hard,
all-in resident-memory upper bound**, Tier P is
**insufficient**: first specify a bounded allocator/
ownership regime including third-party/native metadata,
actual allocatable sizes, GC residency, failure semantics
and concurrency policy; qualify it separately or
**defer** that production capability. A vague safety
margin does not close the proof obligation.

## Production promotion decision and open boundaries

This document is **research**, not an accepted ADR or
permission to ship a new public cache/pipeline API.

**Already mechanically evidenced for this specific
serial consumer:** overflow-aware ROI plan, abort,
release and same-slot generation reuse, independently
held physical raster-d subscriptions, and exactly
defined requested scratch/packed bytes. Existing
M3 pixel-value oracles remain required.

**Before any M3 production admission:**

1. Decide explicitly whether the concrete consumer
   requires only bounded requested **pixel-payload**
   credit, or truly bounded **whole-process resident**
   memory. Document the selected scope in a new ADR;
   do not relabel one as the other.
2. Fix the supported serial/single-thread model
   and the concrete ROI/input fixture bounds; no
   unspecified global source/cache/queue API.
3. Specify storage/metadata limits separately from
   the pixel-credit ledger, with a justified policy
   for actual malloc/GC/import failures. Either
   qualify overhead or declare it explicitly out
   of the hard-payload budget.
4. Ensure the actual owner lifetime cannot escape
   the consumer-level accounting record. Real
   released references must be reflected in credit
   and no externally copied raw lease may bypass it.
5. Retain the DMD/LDC independent consumer and
   full RGBA pixel-oracle gates, LDC optimization
   evidence and documentation/ABI review.
6. Admission requires its own ADR/gate decision.
   Keep Issue #74 and stacked Draft PR #73 open.

No changes to `raster-d`, `color-d` or the
production `imagery-d` surface are entailed by
this research-only quota proof.
