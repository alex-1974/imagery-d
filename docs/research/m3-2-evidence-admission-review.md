# M3.2 — evidence synthesis and production-admission decision record

**Date:** 2026-10-13  
**State:** research synthesis, **not a production ADR**, merge authorization,
public API freeze or release qualification.  
**Subject:** image-semantic checked three-component display mapping over
`raster-d` common-grid views, with immutable intrinsic channel metadata,
explicit component bindings, optional validity and physical calibration.
**Decision vocabulary:** **ADAPT** the proved contracts when a concrete
M3 consumer is selected; **DEFER** direct public/API production promotion,
persistent Prepared ownership and new general-purpose infrastructure.

This is a review waypoint for
[M3.2 parent Issue #24](https://github.com/alex-1974/imagery-d/issues/24),
not its closure or an assertion that all M3 gates have been satisfied.
The repository's [ROADMAP](../../ROADMAP.md) names M3
*First Production Vertical Slice* and explicitly requires selection and
a separate accepting/rejecting ADR before a production package surface.
The [README](../../README.md) still records **no production
`dub.sdl` or `source/` tree**.

## 1. Evidence ancestry and required disposition

The M1 common-grid ImageView and
[accepted M1 ADR 0002](../adr/0002-image-semantic-core.md) establish
an image-semantic view above `raster-d`, not another raster core.
[Accepted M2 ADR 0003](../adr/0003-source-cache-pipeline-architecture.md)
controls source/resource/cache responsibilities. M3.2.1–M3.2.15
research supplies the selected component mapping, validated immutable
image capability, private Prepared binding and checked source-independent
pixel execution. The later experiments investigated lifetime, memory
allocation, ordered numerical evidence and amortization; they did not
change these foundational responsibility boundaries.

The **stack is active**, intentionally non-squashed and evidence-bearing.
Treat its branch ancestry under the grandfather/transition provisions of
the workspace
`.workspace/GIT_GITHUB_WORKFLOW.md`; do **not** merge every stacked
experiment wholesale into `develop` or treat
`research-integration` as a general staging dump.

| Stage | Research question and accepted evidence | Current disposition |
|---|---|---|
| M3.2.12–13 | Module-private checked executor, genuinely immutable validated image, nonforgeable Prepared binding, real three-component pixel oracle and DIP1000 negative escapes. | **ADAPT** private checked semantic plan boundary where an actual consumer needs it. Do not copy provisional names directly into the public package. |
| [M3.2.16](m3-2-gc-intervention-xps-results.md), [#54](https://github.com/alex-1974/imagery-d/issues/54), [PR #55](https://github.com/alex-1974/imagery-d/pull/55) | Isolated real mutable metadata snapshots under normal, precollection and deferred-GC controls. At 256 channels two mutable-array `.idup` copies cost **17,744 GC bytes per batch**; changing collector scheduling did not make repeated copying a sensible hot-path ownership model. | **REJECT** GC policy tricks as a substitute for one-time ownership conversion. Keep the counterfactual evidence and tails. |
| [M3.2.17](m3-2-metadata-owner-xps-results.md), [#56](https://github.com/alex-1974/imagery-d/issues/56), [PR #57](https://github.com/alex-1974/imagery-d/pull/57) | Independently replayed **60 processes, 1,920 packets**. One immutable snapshot of two arrays per source then many mappings reports **0 new mapping-loop GC metadata bytes**, versus **17,744 per packet** if re-snapshotted. At 32 packets: **96.875% fewer recorded snapshot bytes** in `snapshot_once` than `snapshot_each`, under that chosen lifetime. | **ADOPT** explicit copy-once publication of mutable metadata; **ADOPT** direct borrowing when backing is *already genuinely immutable*. **REJECT** cast-based mutable→immutable freeze. |
| [M3.2.18](m3-2-metadata-source-xps-results.md), [#58](https://github.com/alex-1974/imagery-d/issues/58), [PR #59](https://github.com/alex-1974/imagery-d/pull/59) | Long-lived metadata source with retained immutable arrays and separate raster/mask borrow. Independent audit: **40 OS processes, 2,560 mapping packets, 25,600 ordered ROIs and 153,600 first/last calibrated corner samples PASS**. Old source semantics resist later caller-mutable edits; explicit fresh snapshot reflects edits. **0 measured GC allocated bytes inside mapping calls**. | **ADAPT** metadata generation/owner boundary; retain per-ROI ordered evidence. This adapter is research-only and re-prepares each packet. |
| [M3.2.19](m3-2-source-error-and-scope-contract.md), [#60](https://github.com/alex-1974/imagery-d/issues/60), [PR #61](https://github.com/alex-1974/imagery-d/pull/61) | Failure precedence and output-state semantics: pristine destination/observer buffers on preflight error; later invalid ROI may leave earlier ROI output (non-transactional). Local-primary and local-validity `RasterLease` escape through a Prepared result **compiler-rejected** with DIP1000 on DMD 2.111/2.113 and LDC 1.41/1.43. | **ADOPT** fail-closed errors and explicit partial-progress contract. Port minimal negative tests into regular regression suite when a production API exists. |
| [M3.2.20](m3-2-scoped-prepared-xps-results.md), [#62](https://github.com/alex-1974/imagery-d/issues/62), [PR #63](https://github.com/alex-1974/imagery-d/pull/63) | Scoped single-call Prepared lifetime across multiple *logical* packets. Independent audit **40 processes; 25,600 ordered ROIs**, two metadata generations, **0 measured hot mapping GC bytes**. `reprepare` incurs 1,280 source-defined preparations across 12,800 ROIs; `session` only 40 across the same amount of mapped work. XPS selected-component median ratios `reprepare/session`: **1.104×, 1.002×, 1.026×, 1.033×** for 8×8×4, 8×8×16, 32×32×4 and 32×32×16 respectively, with only **14/20** repeat-group signs favoring the session. | **ADAPT** one safely scoped multi-ROI session when it fits an actual caller. **DEFER** a persistent cross-call Prepared owner: the modest/inconsistent incremental measured win does not establish demand for a new lifetime abstraction. |

The reference per-stage reports retain their *own precise* run controls,
independent oracle and result limitations. This synthesis is a
**decision summary**, not a replacement for any original evidence archive,
PR, build log, negative compiler proof or reproducibility script.

## 2. Contracts suitable for selective production adaptation

1. **Image-specific semantics above `raster-d`:** a typed common-grid
   pixel raster and an optional validity raster are **borrowed**. Their
   storage, layouts/strides and physical lifetime remain responsibilities
   of `raster-d` owners/leases. No duplicate generic raster engine.
2. **Immutable meaning is not a label heuristic:** plane identities,
   intrinsic metadata, selected display component order, colour declaration,
   stored-vs-physical policy and missing calibration are separately checked.
   Neither RGB order nor sRGB transfer is inferred from names.
3. **Publication is deliberate:** `immutable(T)[]` backed by immutable
   storage may be borrowed; `const(T)[]` with possible mutable aliases
   must not be cast to immutable. Explicit `.idup` once per immutable
   metadata generation is proven adequate for the measured workload.
   Snapshot acquisition costs are part of the *caller lifecycle*,
   not a mysterious free conversion.
4. **Checked preparation is private:** metadata count/identity,
   selected channel IDs, calibration, validity/grid contracts and
   binding are verified before use by a private checked map
   executor. Repeated ROIs must not clone semantic metadata.
5. **Caller-controlled result and scoped lifetime:** ROI mapping writes
   into caller-provided raster buffers, with `@safe @nogc` hot-path
   guarantees where demonstrated. A scoped Prepared plan can be used
   for multiple windows only while source, validity and metadata
   lifetimes remain valid. No view/token referencing a local lease
   may escape.
6. **Failure effects are documented:** validation errors before the
   first pixel write leave output and observation buffers untouched;
   failure on a later ROI can leave already written results. A future
   transactional API would need a distinct, explicit implementation
   and memory cost.
7. **Numerical test strength is explicit:** real 3-channel, 256-plane
   calibrated and masked workloads use an independent expected
   per-ROI first/last-channel oracle and a full final-ROI image oracle.
   The six-corner check does **not** independently verify interior
   pixels of *every intermediate ROI*. Production tests should cover
   important intermediate interior faults as needed.

These are *candidate implementation invariants*. The current
`ResearchLongLivedMetadataSource`,
`ValidatedImmutableImage`, `PreparedSemanticMap` and
`SourceRoiError` remain **experimental names and shapes**, not
automatically approved public contracts.

## 3. Explicitly deferred or rejected proposals

- **DEFER** a caller-visible cross-invocation Prepared cache or composite
  raster+mask+metadata owner. M3.2.20 proved only a local,
  scope-anchored *single invocation* spanning multiple logical packets.
  An externally persistent token needs a separate lifetime proof and
  concrete consumer. It was **not** demonstrated.
- **REJECT** mutable→immutable cast-based zero-copy conversion without
  exclusive ownership and a no-escaped-alias proof. No special
  `@trusted` shortcut was justified.
- **REJECT** repeated per-ROI or per-packet metadata snapshotting
  as the default, and **REJECT** GC disabling/precollection as the
  remedy for a lifetime/ownership design mistake.
- **DEFER** new general-purpose arena, `UniqueBuffer`, ref-counted
  metadata resource or `containers-d` facility without a second
  independent consumer.
- **DO NOT CLAIM** universally zero GC activity, zero page faults,
  bounded maximum latency, platform-general speedups or zero
  lifecycle allocation from these selected-component XPS experiments.

The Dell XPS results used LDC 1.41.0 under a `powersave`
governor and OS-default affinity. The local `raster-d` HEAD
`1ea67cb6...` was **not** the peeled release tag `v0.2.0`
(`2f241585...`). The executable itself was absent from
the archived evidence, although manifests/symbols/disassembly
were retained. These do not invalidate the observed outcomes,
but **limit portability, reproducibility and strict tagged-release
performance admission**.

## 4. M3 production-admission gate: current evidence vs outstanding decisions

The root [ROADMAP](../../ROADMAP.md) and [README](../../README.md)
require one **explicitly selected image-domain vertical capability**
with consumer, exact semantics, raster boundary, bounded memory,
correctness reference, real optimized performance, and a separate
ADR before production `dub.sdl` and `source/` may be added.

| Gate | What the research already supports | Still required for production |
|---|---|---|
| Concrete image-domain consumer and scope | [Issue #24](https://github.com/alex-1974/imagery-d/issues/24) explicitly researches a source-independent three-component *display mapping* slice; [Issue #18](https://github.com/alex-1974/imagery-d/issues/18) separately selected a pointwise `color-d` sRGB transfer candidate (closed research). | **Select exactly one smallest production capability**, record actual consuming use case, inputs, outputs and non-goals; do not accidentally treat display component selection as sRGB conversion. |
| API and `raster-d` boundary | Research prototypes prove image meaning above generic layouts, borrow/lease and ROI behavior. | Design minimal idiomatic public symbols, error policy, ownership and DDox contracts; select only the needed source-semantic adapter, not entire research harness. |
| Numerics and failure | Real 3-channel masked/stored/physical mapping; compiler negative escapes, identity mismatches, failure partial-write matrix. | Production-specific independent numerical and negative matrix including interior intermediate ROIs, overlap/failure behaviors and any scalar/layout variants that the selected API claims. |
| Memory/residency | Measured hot-loop metadata GC bytes zero; copy-once snapshot volume explicit; reuse of caller output buffers. | Record **complete consumer lifecycle** memory peak, output and metadata allocation, retained source/mask lifetime, bounded ROI workload; reject surprise allocations on documented hot paths. |
| Performance/provenance | Exact-head four-compiler CI, Dell XPS real-ROI data with independent log replay and process-level caveats. | Exactly tagged `raster-d` dependency consumer test, identified target compilers, full end-to-end costs and reasonable comparator/regression budget; repeat/affinity/environment controls appropriate to any performance claims. |
| Integration/release | Stacked, individually documented draft research PRs and available `research-integration` branch. | **Deliberately extract/adapt** minimal implementation and tests into a topic branch/PR against `develop` after selection. Pass exact-head gates, render/document public API and write **an M3 acceptance/rejection ADR**. |

**Current status:** **M3.2 experimental evidence accepted for
architectural decision-making; M3 production promotion is BLOCKED**
pending the above explicit selection, consumer/API design,
complete validation and ADR. This does **not** mark
Issue #24 or M3 itself closed.

## 5. Controlled next action

1. Use this as the evidence basis for Issue #24's
   accept/adapt/defer decision, with a short separate design
   proposal specifying the selected *consumer-visible* operation.
   A suggested narrow candidate is **an explicit three-component
   common-grid display-selection/physical-value ROI mapping**
   using existing `raster-d` views and opt-in validity semantics.
   It is **not** automatically equivalent to the separate
   `color-d`-backed sRGB transfer slice from Issue #18.
2. Before admission, compare this candidate to the existing
   M3 selection/consumer scope and document why it is the
   *smallest* one. Do not invent general image source/cache
   infrastructure, decoders, CRS binding or renderer APIs.
3. Only if accepted, create a clean implementation-specific
   topic from the current `develop` head, port the minimal
   invariants plus ordinary regression tests, then perform
   production validation and record the accepting/rejecting ADR.
4. Keep independent evidence branches and their stack available
   until an explicit research-history integration decision. Any
   eventual `research-integration` merger must preserve
   active pre-migration work and use the workspace workflow;
   do not wholesale merge research into production.

**This review does not perform steps 1–4 automatically,
create a release, close any issue, or modify another repository.**
