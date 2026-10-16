# M3 RGBA — first result form and ownership boundary (conditional selection)

**Date:** 2026-10-16  
**State:** DESIGN PROPOSAL / CONDITIONAL B PREFERENCE — **not** an accepted
ADR, production authorization, public name/signature/API freeze, merge or release.  
**Tracking:** Design [#75](https://github.com/alex-1974/imagery-d/issues/75),
research [#74](https://github.com/alex-1974/imagery-d/issues/74),
grandfathered [Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73).

## 1. Why decide now

M1 ADR 0002 and M2 ADR 0003 are accepted *architecture*, not public API
permission. ROADMAP M3 requires exactly one independently useful image-domain
production vertical slice with real-consumer motivation and qualified
semantics, memory, failure and performance.

The two-layer, equal-grid, already-resident RGBA8 source-over candidate
now has a complete original XPS performance evidence archive. The measured
research four-PM-mask code from
`58a122e18e037dbf0f42a7509582d7c6e4857002`
passed the five GitHub workflows and the independent 40-case
LDC 1.43.0 XPS qualification. For the four tested meaning/pattern
cohorts its median-of-case-median full-owned fused/old ratios were
0.999782, 1.000252, 1.006288 and 1.023381, respectively:
**all 40 measured case medians remained below the +5% review trigger**.
This is local workload evidence, not a general performance guarantee.
Original executable SHA is independently verified and the combined
manifest now passes **43/43**. See
[m3-rgba-four-mask-xps-independent-results-2026-10-16.md]
(m3-rgba-four-mask-xps-independent-results-2026-10-16.md).

The optimized image-domain computation is qualified in **research**.
The production choice must now be about output ownership and failure semantics,
not another speculative SIMD/hot-loop or cache infrastructure.

## 2. Competing forms and evidence

| Contract question | A — caller-owned four-plane output | B — new packed owned output |
|---|---|---|
| Input | Two borrowed resident four-band `RasterView!ubyte` layers; same grid and ROI | Same |
| Semantic output | Encoded straight-sRGB four-plane RGBA8 | Encoded straight-sRGB packed `SRgba8` via `RasterLease!SRgba8` |
| Image math | Exact color-d v0.2.0 linear-light source-over and opacity | Same shared image math; no second color arithmetic |
| Extra output storage | No hidden pixelbuffer allocation | Current research: one 4N scratch and one 4N packed owner |
| Complete-on-publication | No; partial caller writes after exceptional sample/write failure | Yes; complete success before owner handoff, private scratch discarded on failure |
| Source/output physical overlap | **Not established** through public writable four-plane view | New live allocations cannot physically alias already-live valid source backing in the tested serial owner model |
| Independently retained result | Caller must already own and manage target | Returned owner retained independently from source and previous ROI |
| Current confidence | Broad oracle and DMD/LDC tests, but public noalias contract blocked | Broad oracle, native fault/ownership tests, controlled prepublication, XPS |
| Remaining risk | Noalias mechanism, target partial-write policy | Allocation/import errors, output ownership, exact accounting with arbitrary lease copies |

The independent `@safe` four-plane alias witness establishes that an
ordinary caller can pass a writable target overlapping source pixels
without the existing research compositor rejecting it. `@safe`
does **not** establish noalias. It is not sufficient to document an
unenforced noalias precondition and promote A as though it were safe
against silent image-semantic misuse. A can become a later explicit
operation only after physical overlap classification **or** a formally
scoped, enforceable exclusivity contract, with an accepted partial-write rule.

**Conditional choice for the first consumer-facing vertical slice: B.**
Make the result a fresh, independent packed owner and keep a
destination-writing calculation as a **private** implementation helper.
Do **not** expose both A and B merely because research contains both.

This is **not yet an accepted product choice**: there is an independent DUB
ROI consumer that demonstrates the need to retain completed results
while sources change and new ROIs are produced, but no external downstream
consumer has formally committed to requiring B. That is the remaining
M3 selection gate #1 / Issue #75 done criterion. No fictional downstream
consumer is asserted.

## 3. Minimal proposed boundary — semantic contract, NOT API syntax

**Domain:** exactly two already-decoded same-grid resident four-channel
`ubyte` images; explicit encoding (encoded sRGB/straight, linear sRGB/
straight, linear sRGB/premultiplied); explicit full-size ROI and finite
upper opacity in [0,1]. Encoded-sRGB/premultiplied remains unsupported.
Full ROI canonical PM RGB<=A is checked before first expensive output
pixel allocation; the values actually consumed by color-d are locally
rechecked in the fused owned path. No implicit resample, clipping,
reprojection, color-profile inference, decoder, NoData conversion,
cache/scheduler, cancellation or concurrency promise.

**Result:** a nonempty, newly created packed `SRgba8` raster of
exact ROI width × height, straight encoded-sRGB, canonical
RGB=0 when final alpha=0. The owner is independent of both source
backings, other output generations and any private scratch. The
caller may retain it after the synchronous operation, or make
ordinary same-thread `raster-d` lease copies under **raster-d's
existing non-atomic ownership restrictions**.

**Staging:** destination scratch and packed output remain private
until the last sample has been computed and written. No partial
owner publication. A partial internal scratch is allowed on failure
because its lifetime ends before return and no consumer can observe it.
Future error or cancellation paths may not expose a partly initialized
owner. A second packed scratch, speculative copy or public
GenerationCache type is not a requirement.

**Borrow/lifetime:** source and prepared LUT input are scope-borrowed
for the call; do not retain view/pointer in the produced owner.
Owners of both sources must remain alive for the whole synchronous
call. This does not establish a *stable value snapshot* under
unsynchronized concurrent mutable access; no multithreaded guarantee
is admitted. The existing local per-pixel canonical PM checks
ensure observed consumed bytes are canonical, but are **not**
an atomic four-channel read or a data-race remedy.

**Prepared configuration:** the 256-entry LUT/opacity can be
caller-prepared and reused, with inert `.init` as already tested.
This does not mandate publishing the research
`ResearchPreparedRgbaContext` name/representation, nor require
a public preparation object in the first version if external
consumer performance does not justify it.

## 4. Ownership and failure rules to qualify BEFORE admission

**No destructive `out RasterLease` interface.** In D an `out`
parameter overwrites a preexisting live resource with `.init`
on function entry. If an output parameter is chosen, it must
be a `ref` to an **empty** `RasterLease!SRgba8`. Validate
emptiness before doing any work. A nonempty target is rejected
without resetting/replacing it or charging another result.
Or use a different result transport after proving its
move/destructor/error contracts. The final public signature
is **not chosen in this proposal**.

| Event / checkpoint | Proposed semantic result | Current evidence / missing gate |
|---|---|---|
| Nonempty prior result target | No work; preserve prior owner | Existing consumer checks empty `ref`; public classified response TBD |
| Bad layer, extent, ROI, opacity, PM bytes | Classified failure, **zero** new pixel malloc, no publication | Preflight + native fault witnesses cover representative invalid cases |
| Checked ROI byte overflow | Classified input/capacity rejection before malloc | Payload budget tests exist; final API policy TBD |
| Requested pixel payload admission denied | No allocation or publication | Single-thread Tier-P experiment; no generic synchronized allocator admitted |
| First physical pixel `malloc` fails | No publication, scratch not created | Native ENOMEM interposer proves refund/no owner in independent research consumer |
| Second physical pixel `malloc` fails | No publication; scratch released exactly once | Native ENOMEM interposer evidence |
| Pre-commit raster import failure | Token stays armed; original owner disposes it | Public `tryImportOwnedRaster` disposition `unchanged` qualified |
| Post-commit raster import failure | Adopted pixels released once, no double-free | Public import fault witness `releasedAfterCommit` qualified |
| Late RGBA pixel/packed-write failure | No publication; partial PRIVATE staging discarded | Deterministic research checkpoints; not a production API test |
| Full success | Publish one fully populated packed owner; old outputs independent | 432-scene oracle, all-pixel owned parity, source-mutation independence |
| Underlying druntime `Error`-class OOM | **No claim of recoverable enum status** | Remains unproven; cannot pretend to catch/recover arbitrary `Error` |
| Source mutation from another thread | **Unsupported / no snapshot claim** | Existing non-atomic lease restrictions; requires separate design |
| Later unrestricted raw lease copies and cache eviction | Result lifetime follows `raster-d`; exact global budget refund **not** available | Research #74: no exposed last-owner callback |

On success, an independently retained copy is another reference to
the **same** physical output owner, not a new 4N pixelbuffer. On failure,
the prior valid output (if misuse supplied a nonempty `ref`) must stay
unchanged. Never conflate an empty published owner with a successful
zero-size raster: zero-size ROI is rejected.

No public general-purpose `try` promise is approved yet:
the current native helper can throw `Exception` on allocation
failures, and the D runtime may raise a nonrecoverable
`Error` on metadata/GC exhaustion. Whether a production wrapper
uses a qualified fallible result or propagates such exceptions must
be explicitly designed and tested. Any claimed `@safe`,
`nothrow`, `@nogc`, DIP1000 or full-allocation-free behavior
requires actual compiler gates; do not transfer those attributes
from the private pixel emitter to the entire allocating producer.

## 5. Memory and delivery contract

For `N = checked(roi.width * roi.height)`, current B research uses:
**4N requested four-plane scratch + 4N requested packed owner =
8N requested-pixel peak, 4N requested-pixel retained**.
These figures are *obligations for requested pixelbuffers* in
the current serialized implementation, not whole-process/allocator
peak-RSS guarantees. Import metadata, native allocation overhead,
`raster-d` control blocks, existing source memory and unrelated
retained results are outside 8N.

The consumer may set a checked per-call ROI/payload limit or employ
an **external** scheduler/admission policy. A single thread's
successful byte-size inequality does not reserve system memory.
Do **not** copy the research `GenerationAccounting`,
`GenerationDelivery`, `GenerationCache` or global scheduler into
the first imagery-d public package.

**Crucial #74 separation:** bare `RasterLease!SRgba8` can be copied/
retained independently. While that supports lifetime safety,
`raster-d v0.2.0` has no public exact last-owner-release event.
A caller-side cache cannot safely refund an **exact** retained
physical-budget charge merely upon eviction if arbitrary external
copies exist. The first owned compositing operation therefore
**does not advertise exact cache-wide residency accounting**.
The accepted M2 retained-subscriber architecture is preserved,
but its general production delivery/accounting remains deferred,
not replaced by sample-only control. If a real downstream
consumer requires exact bounded cache delivery, investigate #74's
controlled-delivery versus conservative-accounting alternatives;
do not mislabel a conservative upper bound as exact bytes or
silently modify `raster-d`.

## 6. Next bounded qualification and hard stop

**Research decision:** choose B as the *single conditional
publication form to qualify next*. Keep the checked,
four-mask fused math and early preflight unchanged; retire
no existing XPS artefact or grandfathered research branch.

Before proposing an accepted M3 ADR:
1. Name a concrete non-test consuming application or library and
   its need for independently retained output rather than supplied A.
   If no such demand exists, mark B **DEFER** rather than invent it.
2. Prototype only a **minimal, separately compiled**
   B producer in `imagery-d` research/feature staging
   with documented resource ownership and tested failure
   classification. No research accounting/caches/deployment tracer
   under `source/imagery/` by bulk copying.
3. Prove its complete externally compiled failure matrix:
   empty/nonempty `ref` owner, invalid ROI/PM before malloc,
   first/second native `malloc`, pre/postcommit import
   disposition, late local PM mutation, partial private
   packed write, owner copy/source independence.
4. Qualify actual package import/link + negative
   compile-contracts and all required DMD/LDC debug/release
   claims, including `.init` and result lifetime.
5. Benchmark the **actual separately compiled, minimal** owned
   package in LDC release against the pinned
   `58a122e...` research reference; detect any
   difference in whole-call work or binary/code size.
6. Write a numbered M3 admission ADR that either ACCEPTS
   the verified minimal form or formally REJECTS/DEFERS it,
   with explicit module/name/failure/owner/memory contracts.

**Stop immediately** if the only way to make B public is an
unproven recoverable GC/allocator-OOM promise, unsafe
manual backing/refcount duplication, silently unchecked PM
inputs, unspecified source lifetimes, or a cache budget
which can be refunded while live arbitrary raster leases remain.

**Current disposition: CONDITIONAL-B / DESIGN-ONLY.
No public package changes; no merged PR, API freeze, release,
sibling repository writes or reinterpretation of native XPS evidence.**
