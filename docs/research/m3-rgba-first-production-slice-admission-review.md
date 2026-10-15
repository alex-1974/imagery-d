# M3 — RGBA source-over first production-slice admission review

**Date:** 2026-10-15. **Status:** PROPOSAL — not an accepted ADR, public API,
production-package permission, freeze, merge or release.
**Context:** imagery-d research Draft PR #73 (grandfathered stacked base
research/m3-decoded-rgba-tiles-consumer), Issue #74 and the
[dedicated M3 Design decision Issue #75](https://github.com/alex-1974/imagery-d/issues/75).

## Proposed scope decision

**Select two-layer, same-grid, already-decoded RGBA8 source-over as the
candidate image-domain vertical slice**, not the experimental cache or
source/processing framework. Its semantic model, reference oracle and
both independently useful publication variants have concrete research
evidence. The publication choice is **NOT YET ACCEPTED**:

**A. Caller-owned destination kernel (smallest reusable operation).**
The current experimental prepared call consumes borrowed four-band
RasterView!ubyte inputs and writes to a supplied four-band
WritableRasterView!ubyte destination. It is @safe nothrow @nogc,
does not allocate an output or retain source views, and uses a
separate caller-owned prepared 256-entry runtime decode LUT.
**Blocker:** the caller's physical source/output non-overlap
precondition is not independently verifiable through this public
raster-d view representation; unexpected write/read failures can
leave partially mutated caller storage. Resolve those public
semantics before promotion.

**B. Complete-on-publication owned packed result (conditional
consumer choice).** The independent consumer's private helper
creates one four-channel scratch and one separate SRgba8 packed
result, then publishes a RasterLease only on complete success.
Requested-pixel memory is 8N at producer peak and 4N retained.
A serialized closed-world coordinator has now *mechanically*
verified exact Tier-P admission before allocation, abort/refund
and last-owner retirement. **Blockers:** native malloc/import
failure categories and post-commit disposition, deterministic
preflight timing and publication API semantics need qualification;
the current private helper can still throw on native resource
failures. A Tier-P quota does not imply an RSS cap.

**Recommendation:** consider A first when the real consumer can
provide a nonoverlapping destination and accept explicit
partial-write semantics; otherwise justify B as the one
minimal consumer-facing owned variant. Do not automatically
promote the research GenerationCache, GenerationAccounting,
GenerationDelivery, private context/error enum names, or a
global scheduler. No public name/signature is frozen here.

## Performance consequence of not promoting research delivery scaffolding

The [independently qualified two-subscriber XPS delivery benchmark]
(m3-rgba-delivery-workflow-xps-2026-10-14.md) found a
**+11.9–13.7 ns median paired increment for a two-subscriber hot
cache hit** in the controlled delivery variant relative to raw
RasterLease retention (**about +44–50%** at that tiny operation
granularity). A full ROI cycle showed much smaller and variable
differences; those results are *not* an additive per-pixel cost.
This is a material reason **not** to promote all experimental
generation/cache/delivery types as part of a first domain
compositing operation. It is **not** a claim that the whole
imaging compositor has a 44–50% regression, or that a later
optimized public owner wrapper must incur those exact costs.

## Existing concrete semantics

Research source:
experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d

- Two equal, nonempty, 0,0-anchored common-grid input RGBA8 images,
  four independently interpreted R/G/B/A bytes per pixel.
- Encoded sRGB/straight, linear sRGB/straight and linear
  sRGB/premultiplied are supported. Encoded/premultiplied is not;
  linear-premultiplied RGB must be no larger than alpha.
- Upper opacity is finite in [0,1], scales linear premultiplied
  color *and* alpha. Color conversion/premultiplication/source-over
  belongs to published color-d v0.2.0, not duplicate imagery logic.
- Output is encoded straight-sRGB RGBA8; fully transparent output
  RGB is canonical black. Exact ROI output, no silent clipping,
  full-frame allocation or implicit resampling.
- The prepared 256-double decode table has 2,048 bytes of state;
  it holds no raster ownership, and its invalid initial state is
  inert. Source owners remain external.
- Dependencies are the read-only pinned raster-d v0.2.0
  2f2415851e45001df92ce56dad409f680684ba8d and
  color-d v0.2.0 3359f08f4e83941ac1a8451cadefb146b5736019.

## M3 roadmap: thirteen selection facts

The statuses here describe **research evidence**, not production
admission. See the root ROADMAP.md M3 selection/exit gates.

| # | Required selection fact | Status and evidence |
|---:|---|---|
| 1 | Concrete consumer requirement | PARTIAL: independent DUB consumer with source-over, ROI reuse and real retained owners. A real downstream application/publication need is not approved. |
| 2 | Capability and non-goals | PROPOSED: one same-grid decoded two-layer RGBA source-over ROI. No decoder, I/O, georeferencing, generalized source/cache, scheduler or mosaic. |
| 3 | Input/source | RESEARCH PASS: resident four-band RasterView!ubyte input, source owner held by caller. |
| 4 | Semantic output | RESEARCH PASS: linear-light source-over and straight encoded-sRGB RGBA output; explicit noalias/partial-write public choice still OPEN. |
| 5 | raster-d boundary | RESEARCH PASS: raster-d owns generic views/strides/leases/imports; imagery-d interprets image bytes and layer opacity. |
| 6 | Source/resource/revision | N/A for already-resident borrowed input; no invented SourceId/cache key. |
| 7 | Region/residency | RESEARCH PASS for logical ROI and exact 8N/4N requested owning-pixel obligations; no whole-process RSS upper bound. |
| 8 | Correctness oracle | RESEARCH PASS: 432 independently computed scenes and 51,840 channel comparisons including alpha, layout and ROI boundaries. |
| 9 | Failure/cancellation | PARTIAL: classified invalid input, no writes on deterministic preflight rejection, owned publish-on-success. Unexpected output failure can partially write; genuine native OOM/post-commit guarantees and threading not admitted. |
| 10 | Memory budget | RESEARCH PASS for serialized Tier-P requested-pixel quota only; physical Tier-R memory NOT QUALIFIED. |
| 11 | Benchmark workload | RESEARCH PASS: XPS mixed/transparent ROI matrix, reused versus owned output, and hot/cold subscriber delivery. Real consumer acceptance threshold still OPEN. |
| 12 | DMD correctness | RESEARCH PASS: 2.112.1/2.113.0 debug/release and positive/negative lifetime contracts. |
| 13 | LDC optimized performance | RESEARCH EVIDENCE: 1.42/1.43 CI and XPS release benchmarks; separately compiled public package and codegen gate not yet measured. |

**Frozen review baseline:** imagery-d commit
3f2fae6e46c300ddb280451720243924afc1d8e8.
All five GitHub workflows for that exact research head completed
SUCCESS, including DMD/LDC independent debug/release tests of
the one-byte-below Tier-P admission refusal. CI success of a
research consumer is not a public API freeze.

## Tier-P contract and non-contract

For N checked ROI pixels in the currently fixed serial owned producer:

- Scratch request: 4N bytes.
- Packed result request: 4N bytes.
- Producer credit: 8N, acquired before first new producer buffer.
- Published credit: 4N, held once per distinct physical generation,
  independently of cache slot and number of subscribers.
- Accounting invariant: used = sum(8N for RESERVED generations)
  + sum(4N for PUBLISHED generations).
- New admission requires checked(8N), available ticket/slot,
  and 8N <= quota - used; unsuccessful admission must not
  allocate the new ROI or mutate old owner/accounting state.
- Abort refunds reserved credit; publication refunds the 4N
  transient part; final genuine backing owner refunds remaining 4N.
- An old A 16x16 packed output owns 1,024 requested bytes.
  A new B 16x16 producer needs 2,048 peak bytes. Therefore
  3,071 B total quota rejects B and 3,072 B admits B, even
  while two independently retained A subscribers still exist.
  This is a tested real-owner boundary in both Debug/Release.

**Tier P is not Tier R.** These are requested pixelbuffer
sizes, NOT allocator usable sizes, GC heap, malloc overhead,
native raster-d metadata, transient input/storage,
total resident process memory, guaranteed successful allocation,
or thread-safe shared admission. The prior 128/64 B illustrative
metadata charges and observed native 24/40/88/96 B malloc
requests, +256 B current-thread GC allocation, and
48/72/48/24 B shared GC table trajectory are not certified
per-generation physical overhead constants.

If publication form A is selected, the compositor performs no
hidden pixelbuffer allocation; a Tier-P owning-cache coordinator
is not a necessary part of that kernel's public surface.

## Outstanding production gates (stop conditions)

**B1 — Choose one public result form by real consumer need.**
Document whether a caller-provided output is adequate or an
independently retained SRgba8 RasterLease result is necessary.
Avoid shipping two redundant public forms solely because
both are present in research.

**B2 — Aliasing and failure semantics.**
For destination output, close the source/destination noalias
contract and state whether partial output on unexpected failure
is permitted. A @safe annotation proves memory safety, not
nonalias image semantics. Where alias misuse risks silent
wrong pixels, prefer a mechanism that establishes the invariant
over an untestable promise. For owned output, preserve no
publication until completely constructed.

**B3 — Native allocation/import failure.**
For B, qualify validation before significant allocations,
first/second allocation failures, correct raster import
resource disposition (unchanged versus releasedAfterCommit),
injected late packed write failure, and output/credit/refund
postconditions in release builds. Do not clear a live owner
through an out parameter. Existing native Error-level OOM
handling is not proved recoverable by a logical quota.

**B4 — Capacity scope and concurrency.**
Either explicitly declare no hidden allocation for A or
Tier-P requested pixels for B. No RSS budget is supported.
This experimental GenerationAccounting has three fixed
records/two slots and non-atomic lease participants, so
concurrent cancellation or multi-worker publication cannot
be silently included.

**B5 — Minimal production package and benchmark.**
Only after one form's error/alias contract is chosen: build
the smallest imagery-d source module, with public Ddoc,
import/negative-compile contracts and external package smoke.
Do NOT copy the huge research DUB consumer, benchmarking tools,
tracers or generation-cache scaffolding into the release.
Requalify DMD/LDC correctness and performance against
the actually packaged code and final selected consumer workload.

**B6 — Accepted M3 decision ADR.**
A numbered ADR must explicitly accept or reject
the selected production surface, module/import names,
type/failure and inert-initial-state policy, allocation
guarantees and qualification evidence. This document is
NOT that ADR and creates no API freeze or release permission.

## Evidence

- [RGBA semantics and independent oracle](m3-rgba-layer-compositing.md)
- [Prepared-context and noalias limit](m3-rgba-scoped-prepared-context.md)
- [Owned-result native failures](m3-rgba-owned-result-budget-failure-contract.md)
- [Exact Tier-P test](m3-rgba-bounded-payload-admission-contract.md)
- [Native XPS owned-result benchmark](m3-rgba-owned-result-xps-results-2026-10-13.md)
- [Delivery-workflow performance](m3-rgba-delivery-workflow-xps-2026-10-14.md)
- [XPS physical-memory contradiction](m3-rgba-native-kernel-peak-c-xps-2026-10-15.md)
- [Accepted M2 architecture](../adr/0003-source-cache-pipeline-architecture.md)

**Next action:** resolve B1 and B2 first, through a bounded
contract comparison of the two existing source forms, rather
than extending a speculative cache framework. If B is
needed, qualify B3 in the independent consumer before
promoting a public owner API. Leave the active stacked PR
and all neighboring repositories untouched.
