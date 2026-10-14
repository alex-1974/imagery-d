# M3 RGBA — Issue #74: two-subscriber retained-delivery accounting

**Status: research-only bounded consumer experiment; NOT a production or public delivery API.**
The evidence is in the stacked, open Draft PR #73. Its base must remain
`research/m3-decoded-rgba-tiles-consumer`. All code changes are confined to
`imagery-d`, using **public raster-d v0.2.0** operations without modifying
its private control blocks.

## Source of requirements and scope

- [imagery-d #74](https://github.com/alex-1974/imagery-d/issues/74):
  decide if consumer-owned delivery can account for cache and **two
  independently retained subscribers**, before demanding new raster-d API.
- [raster-d #250](https://github.com/alex-1974/raster-d/issues/250):
  a non-atomic public refcount snapshot does not provide automatic last-release
  notification, and cannot by itself justify final-credit refund.
- [M2 source/cache ADR 0003](../adr/0003-source-cache-pipeline-architecture.md):
  multiple delivered subscribers may outlive a cache eviction; copied
  raster handles continue to retain the genuine physical backing.
- Previous [single-subscriber closed-world proof](m3-rgba-closed-lease-retention-contract.md)
  does not prove the two-subscriber requirement.

## Executable proof (separate DUB consumer)

`experiments/m3_rgba_layer_compositing/smoke/source/app.d` now executes
`checkTwoIndependentRetainedSubscribers()` using a research-only,
`@disable this(this)` `ScopedMultiSubscriberCacheProbe`:

- Holds two cache entries and **two independently releasable subscriber
  slots per entry**. Each slot contains a genuine public
  `RasterLease!SRgba8` copy, retained from the original cache owner;
  *no custom pixel backing or shadow raster reference counter* is created.
- Controls publication via the existing real composite, publicly imported
  raster-d malloc backing, and `RoiReservationLedger` test harness.
- Gives callers only copies of `SRgba8` pixel *values* read under scoped
  `RasterView` borrows. It does **not** export a retained lease handle.
- Issues a cache eviction and subscriber retirement as **distinct
  transitions**. A backing remains charged while any of its known private
  cache/subscriber handles remains present.
- Rejects stale reads, duplicate subscriptions, duplicate release,
  out-of-range subscriber slots and premature overwrite/re-use.
- Accounts by **materialization/backing**, not by subscriber count.
  The accounting amount is the experimental ROI payload + *illustrative*
  metadata headroom, not a certified physical-residency measurement.

### Deterministic 16×16 ROI scenario (budget 3,400 bytes)

The current research lease allocation has 1,024 bytes of packed pixel payload
per delivered ROI. The fixed test allowance is **64 bytes** delivered
metadata per ROI (not empirically measured), so each delivered ROI is charged
**1,088 bytes**. The in-flight reservation is 2,048 bytes of simultaneous
pixel payload + **128 bytes** illustrative overhead = **2,176 bytes**.

| Step | Known owners | Delivered accounting charge |
|---|---|---:|
| Create A | cache A | 1,088 |
| Retain A subscriber 0 and A subscriber 1 | cache A, A-sub0, A-sub1 | 1,088 |
| Evict A | A-sub0, A-sub1 | 1,088 |
| Create B | A-sub0, A-sub1, cache B | 2,176 |
| Retain B-sub1 and evict B | A-sub0, A-sub1, B-sub1 | 2,176 |
| Retire/cancel A-sub0 | A-sub1, B-sub1 | 2,176 |
| Retire B-sub1 | A-sub1 | 1,088 |
| Re-create and evict unsubscribed B | A-sub1 | 1,088 |
| Retire A-sub1 (last **controlled** A owner) | none | 0 |
| Re-create and evict A | none | 0 |

The independent real backing of B is accounted separately from A. A-sub1's
pixel values are compared byte-for-byte against A-sub0's original content
after A-sub0 has retired, and all pixels of independently produced B are
compared against both subscribers of A before retirement. Failed admission
under **2,175** bytes (one byte short of 2,176) must leave no charge or
published owner.

The existing 432-scene independent RGBA pixel oracle and prior negative
failure tests continue to run in the same four-compiler consumer matrix.
No XPS timing is inferred from this functional test.

## Three alternative delivery boundaries (#74)

| Choice | Accounting semantics | Current evidence / blocker |
|---|---|---|
| **A. Controlled delivery** | A single physical raster-d backing; imagery controls all owning cache/subscriber handles and refunds only at the last **controlled** retirement | Tested for two independently releasable *slots* in a closed-world synchronous consumer. A consumer-independent, transferable, long-lived Delivery capability still needs explicit D lifetime/copy/move validation. |
| **B. Escaped raw RasterLease** | A safe **conservative outstanding charge** can be held, but exact total-retained physical residency cannot be refunded solely on cache eviction | No public ability to observe arbitrary last-held lease. Any timeout or cache eviction as refund event could undercount. |
| **C. New raster-d lifetime observation** | Exact last release could require a notified *final release*, not simply a refcount snapshot | Would need precise lifetime/synchronization/error/overhead contracts and a separate raster-d decision. Not implemented or requested as a production change here. |

## Evidence limits (explicitly not yet proven)

1. A **real independently transferable delivery handle** with safe
   copy/move/destructor lifetime and external subscriber ownership has
   **not** yet been built. This consumer instead keeps all lease copies
   privately and indexes two separate subscriptions by slot.
2. Not thread-safe. raster-d's existing reference count is non-atomic and
   there are no locks or scheduler in this bounded proof.
3. No automatic last-raster-lease hook. Ledger refund is correct only
   under the test's explicit closed-world knowledge.
4. Exact release timing of **arbitrarily escaped raw leases** remains
   unobservable. No request to expose internal refcounts is resolved by
   this experiment.
5. No per-subscriber allocation-cost measurement, controlled threads,
   source-snapshot/cancellation race or API escape/DIP1000 negative matrix
   specific to a new public handle. Existing ROI emission/fault-injection
   probes do not substitute for those tests.
6. Budget numbers are **test charges**, not guaranteed native allocations,
   process RSS or a quantified all-in metadata upper bound. Do not use as
   a production admission threshold.
7. All workspace rules still apply; no dependency/toolchain or release
   changes and no branch integration is authorized by this document.

**Interim disposition:** Issue #74 is **partially evidenced**, not closed.
The second independently controlled subscriber is proved by executable
test (subject to exact-HEAD CI); a genuinely separately held delivery
capability and independent destructor-accounting behavior remain the next
decision. In particular, this does not close raster-d #250 or alter
Candidate A's blocked arbitrary cross-type overlap contract.
