# M3 RGBA — Owned-result memory admission and failure contract

Status: **research proposal and arithmetic probe; no public API or admission ADR**.
The active Draft PR #73 remains stacked on Draft PR #69. Only imagery-d changes.
The accepted M1 and M2 ADRs and the workspace ownership, failure and quality
rules continue to apply.

## Decision problem

The 20-case native XPS study establishes neither a material general speed
advantage nor a production allocation contract for freshly owned packed output.
Candidate B remains useful for **complete-on-publication** results, but the
current independent consumer throws on native allocation/import failures,
does not make an actual memory reservation, and performs some source-metadata
validation after allocating four-plane scratch.

M2 ADR 0003 §§11, 12, 30 and 40 requires transactional semantic publication,
retained backing through raster-d, separate pinned/in-flight/overhead accounting,
memory admission before production, and distinct invalid-input, cancellation,
and admission failures. It explicitly does **not** freeze an allocator, scheduler,
accounting type, or public error enum.

## Checked pixel payload model (research only)

The new executable pure, safe, nothrow, nogc check is in
experiments/m3_rgba_layer_compositing/smoke/source/owned_payload_budget.d.
The existing DUB consumer calls its probes in both ordinary and benchmark
runs. This computes **pixel payload**, not full allocator or cache residency.

For a nonempty region with N = width times height, with checked extents,
product and signed row-stride arithmetic:

- Four-channel interleaved ubyte scratch: 4N bytes.
- Independently allocated packed SRgba8 result: 4N bytes.
- Peak simultaneous new ROI pixel payload: **8N bytes**.
- Retained packed payload after complete publication: **4N bytes**.

| ROI side | Scratch | Retained | Peak simultaneous payload |
|---|---:|---:|---:|
| 16 | 1 KiB | 1 KiB | 2 KiB |
| 32 | 4 KiB | 4 KiB | 8 KiB |
| 64 | 16 KiB | 16 KiB | 32 KiB |
| 128 | 64 KiB | 64 KiB | 128 KiB |
| 256 | 256 KiB | 256 KiB | 512 KiB |
| 512 | 1 MiB | 1 MiB | 2 MiB |
| 1024 | 4 MiB | 4 MiB | 8 MiB |

The planner checks zero and coordinate extent, byte-stride representation,
multiplication overflow, exact budget acceptance and one-byte-below-capacity
rejection. All rejected calls return an inert output plan. The planner itself
performs no allocation, takes no reservation and does not retain state.

**Limit:** Two native raster imports also need allocation metadata and control
blocks; prepared LUT, source owners, process stack, allocator overhead, cache,
other retained results and backend memory are not included in 8N. Report those
separately and enforce a total budget at the real admission coordinator.
A pure inequality test is not a reservation and does not prevent simultaneous
requests from exceeding the same available memory.

## Proposed scoped production sequence (not implemented)

1. Check caller output emptiness, input image semantics and ROI bounds
   **before expensive native allocation**. No silent ROI clipping.
2. Check all extent/row-stride/payload arithmetic.
3. Obtain **actual** admission for at least 8N ROI payload plus budgeted import
   metadata/overhead. Account for pinned sources and existing delivered
   raster resources separately, without double-counting copied leases.
4. Allocate the genuine four-plane scratch and use the existing prepared
   compositor. On classified failure release scratch and publish nothing.
5. Allocate the genuine packed owner, write the complete packed ROI, and
   publish its single retained backing **only after every write succeeds**.
6. Release four-plane scratch and its reservation; keep result residency charged
   until the last result owner is no longer retained. A lease copy is not
   another independently freed allocation.

A future viewport consumer must define who owns that accounting obligation and
when it is released. The existing public raster-d v0.2.0 lease API does not
supply a generic exposed memory-accounting lifecycle callback; do not invent
another backing owner to make the counter work. No global scheduler/DAG is
justified by the local RGBA experiment.

## Proposed failure and resource-state matrix

| Event | Intended published result | Established vs missing evidence |
|---|---|---|
| Nonempty output target | Preserve existing retained result | Current prototype throws before work; public error choice open |
| Invalid metadata/opacity/ROI | No new result | Image errors classified; some checks currently run after scratch allocation |
| Zero region, overflow, too little *pixel* capacity | No new result | Pure probe passes its compile-contract checks; not a full reservation |
| Actual memory admission denied | No new result | Not implemented or injected |
| First native allocation fails | No new result | Consumer helper throws; recoverable classification not implemented |
| Second native allocation fails | No new result | Consumer helper throws; injected resource-release proof still missing |
| Ownership adoption/import before commit fails | No new result | raster-d reports disposition unchanged; adapter must retain/release obligation correctly |
| raster-d import fails after commit | No new result | raster-d reports releasedAfterCommit; must NOT double-free |
| PM/quantization/image failure | No new result | Negative consumer tests cover inert context and invalid PM |
| Late packed write failure | No new result | Early return exists; deterministic late fault injection missing |
| Cancellation before publication | No new result | Future boundary only; no cancellation execution semantics claimed |
| Full success | One complete packed owner | 432-scene byte oracle + shared-input-owner tests passing |

The raster-d owned import API returns **both** its error category and
resourceDisposition (unchanged, transferredToLease, releasedAfterCommit). The
new adapter must use both; naive freeing after every import failure risks
double release. Some control-block resource failures may raise Error-level
allocation failures; no claim is made that all OOM can be converted safely
to a recoverable enum.

Workspace D rule: do **not** use an out argument for a potentially live
RasterLease. out initializes a previous owner to .init on entry and may discard
its release obligation. The research candidate correctly requires an empty
ref RasterLease result; a future API must document failure-state preservation
and test it under deliberately populated outputs.

## Admission blockers and next evidence

- Add a concrete reservation and fault-injection experiment *inside imagery-d*
  driven by a real viewport/ROI consumer; do not promote a universal allocator.
- Prove first/second allocation rejection; ownership-token import pre- and
  post-commit disposition; exact-once release; full late-write failure; and
  two competing reservations, including copied/retained result owners.
- Quantify metadata/overhead and distinguish in-flight, delivered/pinned and
  evictable resources. Preserve M2 cancellation and source snapshot semantics.
- Retain the independent all-pixel oracle and DMD/LDC attribute matrix.
  Include a second native consumer-representative timing session before a
  release/performance decision.
- Only an explicit M3 admission ADR may select the minimal public production
  operation and failure representation. The source-over research type names
  and payload gate are **not** approved public API designs.

Caller-provided packed output (Candidate A) still has the original four-plane
source vs final packed destination physical alias blocker. Fresh result
ownership (Candidate B) does not establish Candidate A's overlap guarantee.
No merge, branch retarget, sibling writes or release promotion.
