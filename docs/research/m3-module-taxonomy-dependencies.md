# M3 module taxonomy and dependency direction — research design

**Status:** design proposal, not an accepted production ADR, package-name compatibility promise, API freeze or authority to add a root DUB package.
**Context:** [module import executable proof](m3-module-import-surface.md), [M3 selection review](m3-first-production-slice-selection.md), [M3.2 evidence review](m3-2-evidence-admission-review.md), accepted [M1 ADR 0002](../adr/0002-image-semantic-core.md) and [M2 ADR 0003](../adr/0003-source-cache-pipeline-architecture.md).
**Research branch:** `research/m3-module-import-surface`, [Issue #64](https://github.com/alex-1974/imagery-d/issues/64), [Draft PR #65](https://github.com/alex-1974/imagery-d/pull/65).

## 1. Position and principles

`imagery-d` supplies image-*meaning* and image-specific processing for both conventional and scientific/multispectral imagery. Its root is useful without Dunia, an OSM account, GUI, network, special decoder or a colour management runtime.

- `raster-d` owns scalar raster backing, `RasterLease`/`RasterView`, layouts, strides, generic ROI, generic pixel arithmetic, storage, generic halo/dependency and bounded materialization mechanics.
- `color-d` owns colour values, colour models/spaces, component transforms and scalar colour mathematics. No cloned gamut/sRGB formulas in imagery.
- `imageio-d` (under development) owns encoded image format input/output and decoder/encoder APIs. Its concrete API/ownership contracts have **not** been inspected or assumed here.
- `imagery-d` owns image channel/pixel meaning, explicit stored/physical/colour interpretation, alpha/validity separation, image-specific operators, product/source logical coverage and *image*-domain materialization policy.
- A connected OSM editor supplies layer selection, attribution/licensing rules, user profile/workset settings, display widgets and rendering. Those do not enter core imagery imports.

The module taxonomy is a **responsibility map**; creating a name on this page does not require creating a D module, an API symbol, a DUB subpackage or a Git repository.

## 2. Candidate root and groups

| Candidate module root | Scope (imagery-domain only) | Concrete early example and invariant | State |
| --- | --- | --- | --- |
| `imagery` | Small curated import of the essential common-grid image semantics. | Import `imagery` should *not* expose every filter, transform or source manager. | Executable research prototype. |
| `imagery.core` | Common-grid image semantics, channel identity and immutable intrinsic metadata, validity/NoData/alpha *distinctions*, non-owning views and checked construction. | `ImageView!T`-like contract borrows raster/validity; never owns a new raster engine; channel names never imply RGB. | Research prototype for channel/metadata/image; final names unapproved. |
| `imagery.presentation` | Explicit output component binding, interpretation and display preparation; later radiometric stretch/tone; image compositing only with defined colour/alpha semantics. | Three selected channels can be reordered and calibrated; no implicit sRGB encoding or clipping. | Existing binding/metadata-source research proof; no public colour pipeline. |
| `imagery.filter` | Image-specific neighbourhood operations whose behaviour depends on channels, validity, alpha or image boundaries. | An eventual blur/sharpen operation must specify halo, edge policy, nodata/mask handling and output. Generic convolution stays in raster-d. | DESIGN ONLY; no D modules now. |
| `imagery.transform` | Image-domain resizing/regridding and representations requiring explicit sample, validity, alpha and radiometry policies; may use generic raster-d resampling and external coordinate conversion. | Avoid implicit resampling/reprojection and undeclared interpolation/transfer curves. | DESIGN ONLY; no D modules now. |
| `imagery.analysis` | Image-aware statistics, histograms, quality and per-channel measures with explicit masks, sample/physical value policy and reductions. | Generic min/max/reductions belong in raster-d; imagery decides band and validity meaning. | DESIGN ONLY; no D modules now. |
| `imagery.source` | M2 source/resource/revision identities, logical coverage, typed requests and *optional* image-specific materialization/caching policy. | Source is not a URL, resource is not locator, result retains source snapshot, and no hidden mandatory scheduler/cache. | M2 ARCHITECTURE ACCEPTED; public module DESIGN ONLY. |

**Naming choice:** use singular nouns (`imagery.filter`, `imagery.transform`, `imagery.source`) consistently with D's namespace idiom and the already qualified `imagery.core` and `imagery.presentation`. `imagery.filters`/`imagery.sources` are **not** aliases promised by this document. The choice is provisional until the M3 public API admission and import-contract tests.

### Additional concepts deliberately not promoted now

- An eventual **heterogeneous `ImageryProduct` description** (M1.6/M2) can become `imagery.product` if independent consumer evidence demands a public type. It must not be conflated with the single-common-grid ImageView in `core` or with access `source`.
- Explicit alpha compositing can start under `imagery.presentation` if its semantics remain presentation-oriented. A future `imagery.composite` would need a sufficiently independent image-composition domain, not merely one blend function.
- Do **not** create `imagery.color` to duplicate color-d. A later image-specific colour-adapter module may delegate to color-d when a tested image consumer needs it.
- Do **not** introduce `imagery.io` to absorb the developing imageio-d. Any future format/imagery bridge must have a one-way dependency and its own integration tests.
- Georeferencing is **image-associated placement metadata**, not CRS mathematics or a new generic geometry layer. Keep projection arithmetic in its responsible library; image-specific world-to-pixel sampling only after a real scene/workload.
- Cache algorithms, threading, GPU execution and general DAG/schedulers do not deserve mandatory public modules merely because M2 researched optional reuse boundaries.

## 3. Directory *target* (do not create empty files)

~~~text
source/imagery/                 # FUTURE production path, NOT created by this proposal
  package.d                    # module imagery: curated root, currently core only
  all.d                        # module imagery.all: explicit base-family convenience
  core/
    package.d                  # module imagery.core
    image.d                    # public ImageView/checked construction when accepted
    channel.d                  # channel identity, not display order
    metadata.d                 # immutable intrinsic meaning
    validity.d                 # only after a concrete validity/NoData contract
  presentation/
    package.d                  # module imagery.presentation
    channels.d                 # ordered explicit component binding
    tone.d                     # future, only after colour/range policy
  filter/
    package.d                  # future after a real admitted image filter
    ...
  transform/
    package.d                  # future after a real image transform
    ...
  analysis/
    package.d                  # future after image statistics consumer
    ...
  source/
    package.d                  # future after M2 source API admission
    ...
~~~

The **only implemented** module family experiment is under `experiments/m3_module_import_surface/source/imagery/`: curated root, all, core and presentation. Those files currently forward genuinely tested M1.5/M3.2 *research types*, not released public symbols. No new production root `dub.sdl` or `source/imagery/**` is authorized here.

## 4. Package and dependency graph

Proposed *semantic* direction (each arrow means 'may depend on', not 'must link' or 'DUB dependency already declared'):

~~~text
           app / consumer (e.g. CLI, geospatial tool or Dunia)
                |                 |
                v                 v
          imageio-d           imagery-d
                |                 |
                v          +------+--------+----------+
             raster-d       |      |        |          |
                           presentation filter  analysis  transform
                                \     |       |         /
                                 +----+--core--+--------+
                                         |
                                         v
                                      raster-d

           imagery.source → imagery.core + raster-d
           optional colour-aware image operation → color-d
           optional decoded-image bridge → imageio-d + imagery-d
~~~

**No circular dependencies.** The same repo can hold multiple D modules; it does not thereby introduce a dependency of `raster-d` on `imagery-d`. `core` cannot depend on presentation/filter/transform/analysis/source. Each feature family may depend on core; cross-family coupling requires an explicit user-facing semantic reason and is preferably handled by composition rather than a cycle.

Module-import discipline and actual DUB dependency closure are **separate concerns**:

1. `import imagery;` → curated root, intentionally small; today only `imagery.core` in research.
2. `import imagery.core;`, `import imagery.presentation;`, and eventual `import imagery.filter;` → family entry points via explicit `public import` lists.
3. `import imagery.core.channel : ChannelDescriptor;` → supported direct module/symbol import where declared.
4. `import imagery.all;` → convenient bundle of the **base package's actually admitted groups**. If colour/decoder/provider integrations become optional subpackages, importing the base `imagery.all` **cannot** imply those extra DUB dependencies or dynamically aggregate uninstalled modules. Either keep extras explicitly separate, or introduce an explicitly opt-in aggregator package if consumers request it.
5. A D import **does not prove** build-time/link-time dependency isolation or dead-code elimination. Introduce DUB subpackages only when measured build costs, external runtime dependencies or separate consumer packaging justify them; never use an umbrella root to force optional `color-d` or `imageio-d` into minimal core.

Root reexports are curated **symbols**, not blanket export of internal implementation, compiler probes, research helpers, cache strategies or scheduler internals. D modules may still be technically importable; identify the **supported direct-import** surface separately from unsupported implementation modules per `.workspace/DLANG_PRACTICES.md §3.6`.

## 5. Candidate functionality is governed by semantic boundaries

| Candidate capability | Primary proposed family | Other repo / important non-goal | Promotion evidence needed |
| --- | --- | --- | --- |
| Common-grid image channels and metadata | core | Borrow raster-d views; no automatic RGB/NoData inference | external imports, scope/alias negatives, `.init`, storage layout regression |
| Explicit 3-channel stored/physical display mapping | presentation + core | No hidden colour-d sRGB conversion or viewport rendering | M3.2 checked oracle + full intermediate ROI contents, actual consumer, error/validity/units policy, full memory/perf |
| Brightness/exposure/contrast on explicitly declared colour image | presentation | delegate colour mathematics to color-d; no destructive source edit by default | domain/range/gamma/alpha and validity contract, reference colour oracle |
| Gaussian/edge/sharpen image-filter policy | filter | generic generic convolution/halo machinery remains raster-d | mask/alpha/edge/halo behaviour, layout independence, seam tests, speed |
| Image resize/mipmap or regrid | transform | reuse generic raster-d resampling; no hidden CRS decision | coordinate/border/alpha/validity/radiometry policy, scale/edge numerical oracle |
| Band histogram and masked/physical-value statistics | analysis | generic reducers belong in raster-d | mask/NoData/NaN policy, overflow, accuracy, streaming/no-full-image-copy |
| Remote/local tile or product materialization | source (future) | imageio-d decoders external; Dunia selects providers/attribution | identity/revision/coverage, cache keys, cancellation, controlled resident memory, actual decoder adapter |
| OSM-specific XYZ/WMTS layer controls and image-offset bookmarks | consumer (Dunia), optional source adapter | NOT core imagery | OSM editor provider rules and georeferencing consumer boundary |

## 6. Progressive build and promotion plan

**Now:** retain the tested core/presentation/all/root import proof in research, not production. Keep the taxonomy as documentation only. Do not create `filter`, `analysis`, `transform`, `source` empty packages or their DUB subpackages to satisfy this chart.

**M3 first production vertical slice:** select the smallest image-specific capability (candidate: explicit checked three-component display mapping), prove a **real** CLI/non-editor caller, complete invalid-sample/alpha/metadata error contracts, test intermediate ROI pixels and view lifetime negatives, assess full caller acquisition/snapshot/result memory with exactly qualified raster-d release and optimized DMD/LDC consumer workloads, then accept/reject a distinct M3 ADR.

**First production module import proposal:** only if admitted, port small `imagery.core` and the minimal necessary operation in `imagery.presentation`, plus tiny curated `imagery` and optionally `imagery.all`; all admitted names must have stable docs/examples. Import-surface tests from PR #65 are a starting point, not automatically accepted API identifiers.

**Later independently admitted functions:** add `filter`, `transform`, `analysis` only with one numerical and one independent consumer contract each; consider `source` after a real tile/decoded-image materialization reference with imageio-d bridge and M2 policy. `imagery.product` only when a heterogeneous-image consumer truly needs it.

**Quality gates:** directly importing each supported module in an external DUB consumer (DMD/LDC debug/release), negative unknown-name checks on curated root, no source/module cycles, no optional provider dependency through the core, DIP1000 scope/alias negatives, proof of `@safe`/`@nogc` on claimed hotpaths, full raster ROI/layout/numerical invariants, and separately verified package archives when release is authorized.

**Branch discipline:** draft research PR #65 remains stacked above #63. Accepting this *taxonomy research result* is not merging all experimental code into `develop` or an exception to the active grandfather/transition provisions of `.workspace/GIT_GITHUB_WORKFLOW.md`. No sibling repository changes.

## 7. Decision record

**ADOPT as target taxonomy:** `core`, `presentation`, `filter`, `transform`, `analysis`, `source` as distinct responsibilities, with `imagery` as the curated root and `imagery.all` as an explicit **base-package** convenience import.

**DEFER actual modules and public names:** only `core`, `presentation`, root and `all` exist as tested research modules; other package names are design targets pending consumer evidence and M3 production ADR.

**REJECT:** monolithic imagery import dragging mandatory decoders/colour systems into core; duplicated raster-d/filter engines or color-d formulas; automatic sRGB/gamma/NoData coercion; a public cached Prepared handle without lifetime proof; fictitious placeholder APIs and premature DUB subpackages.
