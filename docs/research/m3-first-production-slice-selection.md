# M3 initial production vertical slice — A/B candidate selection

**Decision date:** 2026-10-13  
**Selection status:** **A selected for production qualification**, *not*
production API admission, feature freeze, accepted ADR or release.
**Current production-admission verdict:** **DEFER** until the outstanding
gates below are satisfied.  
**Repository scope:** imagery-d research only; all root
[README](../../README.md), [ROADMAP](../../ROADMAP.md), the accepted
[M1 ADR 0002](../adr/0002-image-semantic-core.md),
[M2 ADR 0003](../adr/0003-source-cache-pipeline-architecture.md) and
[research integration/admission review](m3-2-evidence-admission-review.md)
remain normative. No changes to sibling repositories.

**Selected candidate A:** *explicit, checked, three-component semantic
ROI mapping from a typed already-materialized common-grid image*, with
optional same-grid validity and caller-chosen stored/physical sample
interpretation. Use this as the target for **one narrowly scoped**
production-capability proposal under
[parent M3.2 Issue #24](https://github.com/alex-1974/imagery-d/issues/24).

**Not selected as the first independent imagery-d API:** candidate B,
pointwise encoded-sRGB ↔ linear-light-sRGB transfer through public
`color-d` values. It remains a **valid, previously tested consumer**
for an eventual composition with A, not something to reimplement or
silently combine in the first admitted operation.

## 1. Evidence-based A/B comparison

| Dimension | A: selected semantic three-component display mapping | B: independent `color-d` sRGB transfer | Consequence |
|---|---|---|---|
| Imagery-domain distinctiveness | Converts image-channel identity, explicit three-channel *binding*, raw/physical policy and optional validity into a checked region output; `raster-d` deliberately lacks these higher-level semantics. | Constructs public `color-d` `SRgb!T`/`LinearSRgb!T` values and applies their already-public conversion, while `raster-d` supplies the region/sample mechanics. | **A provides clearer stand-alone imagery semantics.** |
| Consumer motivation | Actual research consumer displays chosen ordered components from arbitrary multi-band raster input, including 256-plane calibrated masked regions. **An independently adopted downstream production consumer is not yet evidenced.** | Actual research consumer consumes existing public value conversion over regions; no additional imagery-specific API problem emerged. | A is a better *candidate*, neither is already admitted. |
| Numerical and layout tests | [M3.2.1](m3-2-semantic-display-results.md): four D compilers PASS, planar/interleaved + full/uneven ROI equality; [M3.2.2](m3-2-channel-metadata-results.md): stored vs physical scale/offset, identity, mask/calibration failure; M3.2.18/20: independently replayed **25,600 ordered ROIs / 153,600 observed corner samples** per XPS run. | [M3 sRGB consumer results](../../experiments/m3_color_d_srgb_consumer/RESULTS.md): DMD 2.113 debug and LDC 1.43 release PASS with independent sRGB formula, exact region-layout equivalence; observed max absolute errors float decode **1.656702637e-6**, encode **2.863535858e-7**, double planar **1.395585036e-15** decode and **2.411265632e-16** encode. | Both independently pass their *research* semantics; A has deeper image-specific ownership/mapping gates. |
| Safety and ownership | M1 DIP1000 and M3.2.12–19 forged Prepared, locally ending raster/validity, immutable alias, caller output and partial failure negative tests pass across **DMD 2.111/2.113, LDC 1.41/1.43**. | Public `color-d` scalar transfer is `@safe pure nothrow @nogc`; the image-region research kernel was `@safe nothrow @nogc`. | A's complexity is justified by a distinct image-semantic role, but requires selective production simplification. |
| Memory and speed | M3.2.17 once-owned snapshot saves **96.875%** of repeated two-array snapshot bytes over 32 packets in its tested lifetime. M3.2.20 scoped session has small/inconsistent XPS ratios **1.104×/1.002×/1.026×/1.033×** for the four selected strata, **14/20** favorable process-group signs, zero measured mapping GC bytes. Initial immutable source construction and full lifecycle costs were excluded from those selected timings. | `@nogc` scalar transfer; caller-owned output, no whole-image temporary. LDC 1.43 **hosted** 512² float characterization about **20.3 ns/pixel** integrated decode versus **4.5 ns/pixel** layout read/write control. Hosted times are not a controlled XPS threshold. | A's preparation/ROI costs are more extensively studied; **neither path has complete production-grade end-to-end memory/performance evidence**. |
| Existing formal disposition | Parent [Issue #24](https://github.com/alex-1974/imagery-d/issues/24) still **OPEN**, research PR stack not integrated to production. | [Issue #18](https://github.com/alex-1974/imagery-d/issues/18) **CLOSED** after merged [PR #21](https://github.com/alex-1974/imagery-d/pull/21), with explicit finding **consumer boundary validated; production admission deferred** because a thin wrapper would freeze premature binding/encoding names. | **Do not reopen B merely to manufacture an imagery-d wrapper**; take A through the M3 selection gates. |

**Important semantic contrast:** A does **not** perform gamma/sRGB
transfer, normalization, clipping, gamut mapping or implicit RGB
inference. B **requires** an explicitly declared encoded-sRGB
interpretation; B cannot be applied automatically to arbitrary
stored or physically calibrated multispectral channels.
The two capabilities may be composed later, but are not synonyms.

## 2. Proposed *minimum* A capability boundary

**Candidate use case (not yet verified as an external consumer):**
an imagery preview/analysis tool already holds a multi-channel
common-grid resident `float` image and needs a deliberate selection
of three input channels, optionally radiometrically calibrated,
in exactly the declared order for a bounded ROI in caller-owned
three-channel result storage.

- **Input:** already retained raster-d `RasterView!float`
  with `N >= 3` source planes in any supported legal layout;
  explicit immutable channel identity/intrinsic calibration
  sidecar; explicit three **distinct** selected source planes
  and `stored` or `physical` mode. Optional same-grid
  `RasterView!ubyte` validity; source/mask resources stay
  owned by their existing `raster-d` leases.
  These are *candidate signature contents*, not frozen
  public identifiers or layout restrictions.
- **Output:** exactly three caller-owned `float` component
  planes in selected component order, covering precisely the
  requested ROI. `stored` preserves represented values;
  `physical` explicitly uses
  `stored * scale + offset` when all chosen channels have
  valid finite calibration. No implicit encoding/RGB conversion,
  scale-to-[0,1], clipping or alpha/NoData interpretation.
- **Validity:** validity is distinct from colour, alpha and
  NoData. The existing *research fixture* maps invalid pixels
  to zero, but that policy must not silently become the
  published production contract. Before implementation,
  explicitly select and test one caller-visible invalid-sample
  policy and how a consumer can distinguish invalid zero
  from a valid numeric zero (for example, retention of the
  separate validity view). Do not create hidden semantics.
- **Ownership/safety:** one-time snapshot when caller metadata
  might have writable aliases; borrow genuinely immutable
  metadata as-is. `@safe @nogc` for mapping where qualified;
  private checked execution and input/ROI verification, with
  bounded caller output and no escaped Prepared capability.
  Do not add persistent cross-call Prepared caching as a
  public feature. Allow optional **single-call scoped batch**
  mapping when a real consumer needs several ROIs.
- **Failure:** reject identity/count/binding/calibration/ROI/
  destination mismatches with explicit error outcomes;
  before-first-write failure leaves outputs unchanged,
  a late ROI error may leave earlier ROI results;
  do not promise transaction rollback without a distinct
  implementation. `.init` source objects are not
  silently valid. Cancellation is **not applicable** to
  this synchronous already-materialized bounded mapping.
- **Non-goals:** no file decoder or imageio/proj/GDAL dependency,
  no M2 remote resource/revision/cache manager, no resampling,
  no global radiometric normalization, no sRGB transform, no
  pixel-format hierarchy, no scheduler, no new raster memory/
  lease or generic arena, and no public exposure of experimental
  `ResearchLongLivedMetadataSource` / `PreparedSemanticMap`
  names as-is.

The product is **a deliberately small image-semantic operation**,
not an implicit generic image framework. An eventual API review
can reject this initial candidate if downstream consumers
already solve it with a smaller, adequately typed composition
of existing primitives.

## 3. Explicit 13-point M3 selection-gate comparison

The current
[ROADMAP § M3 selection gate](../../ROADMAP.md)
lists **13 items** (not 12). The table evaluates the two
candidates and separates facts from remaining decisions.

| # | Roadmap gate | A selected candidate | B nonselected transfer |
|---:|---|---|---|
| 1 | Concrete consumer requirement | **PARTIAL:** independently running multispectral display research consumer; external/production adopter and actual data contract **still to name and demonstrate**. | **PASS as research consumer** through #18/PR #21; no additional imagery-specific API requirement demonstrated. |
| 2 | Exact capability and non-goals | **DRAFT READY:** §2 fixes target semantic mapping and explicit non-goals; no public names committed. | Validated explicit encoded↔linear pointwise transfer; deferred as first imagery public wrapper. |
| 3 | Input/source class | **RESEARCH PASS:** retained typed common-grid, 3/17/64/256-channel variants; production scalar/layout support must be chosen. | Explicit three encoded or linear sRGB channels, finite and extended `float`/`double` test values. |
| 4 | Semantic output contract | **PARTIAL:** three selected stored/physical planes with explicit order; invalid-sample output/validity propagation requires published choice. | Explicit sRGB encoding transition; no clipping or alpha/validity/NoData reinterpretation. |
| 5 | `raster-d` relationship | **RESEARCH PASS:** pixel storage/views/ROI/lease stay in raster-d, semantic binding/calibration in imagery-d. | **PASS:** raster-d handles iteration/ownership, color-d scalar mathematics. |
| 6 | Source/resource/revision behavior if applicable | **N/A for in-memory-only scope:** preserve caller raster ownership and snapshot metadata generation semantics; no remote revision API. | **N/A** for in-memory pointwise transfer. |
| 7 | Region/residency behavior | **RESEARCH PASS:** caller destinations, bounded ROI work and ordered reuse; source is already resident. Full lifecycle peak remains open. | **RESEARCH PASS:** source/destination resident, no halo or hidden full-image temporary. |
| 8 | Correctness oracle | **RESEARCH PASS, PROMOTION PARTIAL:** ordered six-corner oracle each ROI + all pixels last ROI, metadata/layout/lifetime negatives; broader intermediate-ROI interior and error matrix needed for public claims. | **RESEARCH PASS:** independent sRGB formula and exact whole/partition equivalence. |
| 9 | Failure/cancellation if applicable | **RESEARCH PASS/PARTIAL:** error precedence, preflight/no-write and nontransactional partial results; choose final production error form; cancellation N/A for synchronous slice. | Rejected wrong declared semantics; no cancellation for pointwise in-memory slice. |
| 10 | Memory budget/residency accounting | **PARTIAL:** snapshot allocations, hot-path 0-byte GC, source/output accounting; full retained memory/RSS + owner/lease peak **missing**. | Constant per-pixel state and caller result measured structurally; full package memory budget absent. |
| 11 | Benchmark scene/workload | **RESEARCH PASS, PRODUCTION PARTIAL:** calibrated masked 256-plane 8/32 ROI workload, 4/16 reuse; needs full-consumer representative workload and tagged dependency controls. | 512×512 planar/interleaved float, hosted LDC numeric timings; full target benchmark required. |
| 12 | DMD correctness matrix | **RESEARCH PASS:** DMD 2.111/2.113 plus negative tests; actual production API requires separate direct-import tests. | **RESEARCH PASS:** DMD 2.113, independent scalar oracle; targeted floor for eventual public API TBD. |
| 13 | LDC optimized benchmark/codegen | **RESEARCH PASS, PRODUCTION PARTIAL:** LDC 1.41/1.43 CI, reference XPS with codegen symbol/disassembly, but local raster state differs from tagged v0.2.0; no fully pinned consumer-lifecycle baseline. | **RESEARCH PASS/PRODUCTION PARTIAL:** LDC 1.43 release hosted characterization but no target-host/source-pinned imagery package benchmark. |

**Selection verdict:** Candidate **A wins on library-domain distinctiveness
and the directly exercised checked semantic ownership/error contract**.
B is explicitly not the first independent public surface.
**Production admission remains DEFERRED** because gates 1, 4,
8, 10, 11, 13 (and the exact public API/final ADR) remain
incomplete for A. The first public `dub.sdl`/`source/imagery/**`
has therefore **not** been authorized.

## 4. Concrete next, bounded production-qualification tasks

1. **Consumer gate:** name one real caller/consumer of the
   channel-selection/physical-value ROI mapping, supply one
   representative desired call and source/validity data shape,
   and show what existing `raster-d` alone cannot express
   without duplicating image semantics. A hypothetical future
   imagery GUI alone is not independent consumer evidence.
2. **Design gate:** derive a *minimal public symbol/function*
   set from that caller, including exact invalid-pixel policy,
   immutable metadata publication, calibration/units,
   `.init` and error/partial-output effects. Only include
   scoped preparation if the consumer's reuse makes it valuable.
   Keep color-d out unless the caller explicitly requests
   sRGB transfer.
3. **Regression gate:** distill proven semantic/lifetime
   negative cases into ordinary producer/consumer-facing
   tests, including planar/interleaved, masks/mask-free,
   full/partitioned ROI, intermediate ROI interior pixels,
   invalid-binding/calibration/grid/destination and deliberate
   illegal raster/mask/metadata escapes.
4. **Measurement gate:** specify one end-to-end consumer
   workload and memory budget, record source/validity/
   metadata/output retained allocation and peak, compare
   fair raster-only region extraction control, and rerun
   with **exactly pinned released `raster-d`** and current
   baseline DMD/LDC. Document CPU/affinity/frequency
   confounds and full lifecycle setup.
5. **Admission gate:** after gates 1–4, create a deliberately
   selected clean topic from current `develop`, adapt only
   required checked code/regressions, pass workspace
   PR/release-relevant gates and write an ADR explicitly
   **accepting or rejecting** production API admission.
   Preserve all evidence-bearing research branches/PRs and
   grandfather transition history; do not merge the entire
   stack by default.

**No step above has been silently executed or marked completed.
This document is a selection proposal and gate ledger, not an
accepted ADR, API definition, package creation, or issue closure.**
