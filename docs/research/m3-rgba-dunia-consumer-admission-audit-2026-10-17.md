# M3 RGBA — candidate downstream consumer audit: Dunia (not yet admitted)

**Review date:** 2026-10-17  
**Status:** **READ-ONLY DOWNSTREAM AUDIT / PRODUCTION ADMISSION DEFERRED**. No consumer requirement is represented as accepted and no public API is authorized.  
**Tracking:** [imagery-d design #75](https://github.com/alex-1974/imagery-d/issues/75), [retained accounting research #74](https://github.com/alex-1974/imagery-d/issues/74), grandfathered [Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73).  
**M3 evidence:** [independent Direct-4N native XPS qualification](m3-rgba-direct-packed-4n-xps-independent-results-2026-10-17.md) at research source `ec2afbb171d0c6c555386c31de8ddce0877cd74a`.

## Decision question

Which **already existing, non-test downstream caller** demonstrably needs the complete-on-publication RGBA owner? M3 performance evidence answers whether the Direct-Packed 4N implementation is efficient. It **does not** establish a product use case or admit `source/imagery/**`.

Do not substitute an integration test, synthetic benchmark, architectural example or hypothetical editor renderer for a downstream requirement.

## External application inspected (READ ONLY)

Candidate: [`alex-1974/dunia`](https://github.com/alex-1974/dunia), default branch `master`, inspected on 2026-10-17. **No files in Dunia or any sibling repository were modified.**

Sources inspected directly from its repository:

- [`AGENTS.md`](https://github.com/alex-1974/dunia/blob/master/AGENTS.md): Dunia is the OSM editor application/integration layer; add a workspace library dependency only for a concrete application slice.
- [`README.md`](https://github.com/alex-1974/dunia/blob/master/README.md): current first consumer-validation slice is editor themes/styles with `color-d`; GUI toolkit, renderer, OSM editing model and plugin system remain unselected.
- [`DESIGN.md`](https://github.com/alex-1974/dunia/blob/master/DESIGN.md): map-background adaptation, GUI/renderer and orchestration belong to the application, not to color/imagery/raster foundations.
- [`ROADMAP.md`](https://github.com/alex-1974/dunia/blob/master/ROADMAP.md): M1 qualifies `color-d` theme candidate generation; it does **not** declare decoded raster overlay composition as a selected milestone.
- [`dub.sdl`](https://github.com/alex-1974/dunia/blob/master/dub.sdl): executable package with no declared `imagery-d` or `raster-d` dependency.
- [`source/app.d`](https://github.com/alex-1974/dunia/blob/master/source/app.d): `main()` is currently empty.

**Observed:** Dunia is a named, real application repository; **it is not currently a consuming RGBA-layer implementation**. Repository existence is weaker evidence than a shipped, invoked, non-test call path. Do not mark Issue #75's concrete-consumer done criterion complete.

## Potential application integration scenario (HYPOTHESIS ONLY)

A future editor might combine an image background and a semantically separate transparent overlay and retain an independently owned completed viewport/ROI result while source images change. That could justify a synchronous Direct-4N image-domain producer.

**None of the following is currently established by Dunia's checked source or roadmap:**

1. Dunia will own **two decoded, same-grid, four-band RGBA8** layers at the same time.
2. It needs **CPU-side linear-light source-over** rather than GPU/renderer-native layer blending, or a GUI toolkit's own compositor.
3. It needs a finished **packed, straight encoded-sRGB result** rather than a premultiplied texture or a borrowed view.
4. It needs to **retain that result beyond the source lifetimes** rather than immediately render a caller-provided destination.
5. Its map projection, pan/zoom, image placement or tile boundaries have already been resolved to the compositor's **exact same-grid ROI** (the M3 producer does not georeference, reproject, clip or resample).
6. A user- or editor-visible performance/residency requirement actually favors B over A or direct renderer blending.

Therefore **do not introduce `imagery-d` as a Dunia dependency** from this report, nor claim Dunia has chosen a renderer or is ready to bind this API.

## Existing research semantics that a real caller must either need or reject

This section transcribes observed research contracts, **not** a proposed frozen public signature.

| Property | Existing research Direct-4N behavior | Application-level decision still needed |
|---|---|---|
| Input | Two same-grid, 0-origin four-plane `RasterView!ubyte` layers, explicit `RgbaEncoding` and `RgbaAssociation` | Does the app have/produce such resident semantically tagged layers? |
| Accepted interpretation | Encoded sRGB/straight; linear sRGB/straight or linear sRGB/premultiplied | Are these app's source semantics? |
| Rejected interpretation | Encoded sRGB/premultiplied; invalid PM samples (linear RGB component > alpha) | Can the app expose/diagnose these invalid inputs? |
| Operation | Upper-over-lower using `color-d` linear-light source-over and finite upper opacity in [0,1] | Does editor rendering need this exact mathematics? |
| ROI | Nonempty region contained in both equal-grid input sources, no implicit clipping, target exact ROI dimensions | Is there a real ROI caller and no hidden geographic/viewport coordinate conflation? |
| Output | New, independent `RasterLease!SRgba8`; straight encoded sRGB, RGB=0 where alpha=0 | Does the app need this storage/display form and independent lifetime? |
| Publication | `ref` output must be empty; nonempty old owner rejected unchanged; publishes only complete result | Can the application manage and retain owners under this contract? |
| Allocation | Exactly one `4N` **requested pixel payload** allocation in the research direct producer, no four-plane scratch/pack pass | Can the app tolerate a new output allocation per call? Is reuse needed instead? |
| Failure | Classified image-semantic errors; native malloc/import/adoption can throw `Exception`; arbitrary druntime `Error` OOM not promised recoverable | Which errors may propagate into the app's UI/job handling? |
| Borrow/concurrency | Source owners must outlive synchronous call, no unsynchronized concurrent source mutation, `raster-d` non-atomic copied-lease semantics | Is app-side synchronization / frame snapshot ownership available? |
| Accounting | 4N requested output pixel payload only; no RSS or arbitrary external last-owner refund promise | Does the real app require a hard global retained-memory budget? If yes, link #74. |

The current research API is `tryCompositeOwnedRgbaDirectResearch(ref const ResearchPreparedRgbaContext, scope DecodedRgbaLayer, scope DecodedRgbaLayer, Region2D, ref RasterLease!SRgba8)` under **`experiments/m3_rgba_layer_compositing/source/imagery/presentation/owned.d`**. The `Research` names, preparation object and `RgbaCompositeError` enum are **not** accepted public names or layout. The allocating function is not certified `nothrow`/`@nogc` simply because the inner pixel math has stronger attributes.

## Narrow A/B decision for a *future actual* caller

- **B (preferred research path):** new owned `SRgba8` result only after complete success; physical source/output alias is avoided through fresh unpublished raster storage. Case-median Direct/Fused = 0.792041× and Direct/Extracted = 0.709511× on the audited XPS workload; no portable speed guarantee. Best fit **if** the caller actually needs independently retained CPU-produced ROI images.
- **A (still blocked):** caller-provided writable four-band output does not enforce physical source/output disjointness via current public views; a same-backing `@safe` witness was accepted, with possible partial writes after unexpected failure. Its lack of output allocation does not justify unsafe promotion. Consider A only after a demonstrated consumer need and enforceable alias/partial-write contract.
- **Renderer/GPU integration:** an alternative **outside the existing M3 operation**. If the real caller composites directly in the renderer, it might have no need for a CPU `RasterLease!SRgba8` image producer at all. No library-layer duplicate GPU compositor should be added on speculation.

Do not publish A and B simultaneously merely because both occur in research. Do not treat the known 4N payload as a global memory budget.

## Evidence required to resolve the actual consumer gate

An eventual `dunia` image-layer feature (or another genuine application/library) should provide these **observed** facts, rather than a test manufactured only for this decision:

1. **Named production caller:** repository, commit and location of a real editor/image feature which would invoke RGBA composition; its user-facing purpose and representative workload.
2. **Input evidence:** real input provenance, layer count/order, source pixel storage, encoding/alpha association, grid and ROI relationship, and whether the layers exist concurrently.
3. **Output necessity:** the actual downstream output consumer and lifetime (retained vs immediate use), format expected by rendering/texture upload, and why independent packed ownership is materially required.
4. **Alternative check:** reason ordinary renderer/GPU blending or an already owned destination is insufficient, including explicit color-space/alpha/visual-equivalence and transfer-cost considerations.
5. **Realistic acceptance case:** one reproducing fixture/workload with source/expected composited result, output retention after source changes, invalid data/failure behavior, and representative frame/ROI performance. Document measured hardware/compiler/build; do not replace the established correctness oracle with visual inspection.
6. **Package seam:** after B is actually selected, independently build a minimal ordinary imagery-d consumer against the **new production package** with Ddoc, supported DMD/LDC matrix, negative borrow/attribute cases, real allocation/import failures, ownership and codegen/performance gates. The current research DUB consumer does **not** count as that final package gate.

When a real consumer chooses B, write a **numbered M3 admission ADR** with the exact module, names, lifetime, error and allocation contracts. If no concrete downstream need can be established, **DEFER B's public admission** rather than invent a consumer or weakening the selection rule.

## Explicit decision and protected work

- **ACCEPT** the audited Direct-Packed-4N algorithm as a performant **research mechanism**.
- **IDENTIFY** Dunia as a **prospective** named downstream application, but **DO NOT CLAIM** that it presently requires a CPU two-layer compositor.
- **DEFER** the first public owned-RGBA API until a genuine non-test caller supplies the listed requirements.
- **KEEP OPEN** imagery-d Issue #75 and Issue #74. No issue closure/checkmark follows from this audit; #74's cache/subscriber accounting is independent.
- **PRESERVE** Draft PR #73 on `research/m3-decoded-rgba-tiles-consumer`; no retarget, rebase, merge or auto-promotion.
- **NO WRITES** to `dunia`, `raster-d`, `color-d`, other repositories, `develop`, `main`, or `source/imagery`.
