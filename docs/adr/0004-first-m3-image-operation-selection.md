# ADR 0004 (proposed) — First M3 general-image production-qualification candidate

**Status:** PROPOSED FOR REVIEW; **production API admission: DEFERRED**  
**Date:** 2026-10-19  
**Scope:** `imagery-d`, one initial image operator; this is not an API freeze, release or a change to accepted ADR 0002/0003.

## Decision being proposed

Select **general scalar Levels** as the **first M3 production-qualification
candidate**, on the narrow existing ownership and ROI foundation provided by
`raster-d`. It operates on caller-supplied, already materialized image samples
and caller-declared selected channels. **Do not yet create a public
`imagery-d` package or freeze a public signature.**

This is an **explicit proposed change of priority** from the 2026-10-13
[M3 A/B research selection](https://github.com/alex-1974/imagery-d/blob/research/m3-module-import-surface/docs/research/m3-first-production-slice-selection.md)
on the `research/m3-module-import-surface` branch. That selection favored
three-component display mapping with immutable channel metadata and optional
stored-to-physical calibration. Its analysis was sound for its requirements,
but the new 2026-10-17 general-image scope clarification and the 2026-10-19
**working P6 photo-image consumer** provide stronger evidence for a smaller,
more immediately useful first general-purpose operation. **The earlier record
and its CI/measurement evidence remain preserved and historically valid.**
This proposal does not silently rewrite the historical choice or declare
the older research rejected; display mapping stays a later distinct candidate.

The [general-image scope correction (Draft PR #84)](https://github.com/alex-1974/imagery-d/pull/84)
is explicitly still **unmerged**, so this ADR must be reviewed alongside it.
Do not treat that draft as a change already present on `develop`.

## Concrete consumer and operation

A real, separately built **DUB executable in this repository**
([Draft PR #95](https://github.com/alex-1974/imagery-d/pull/95)) loads a binary
P6 RGB8 file, applies Levels over a real `raster-d` lease and writes a new
valid image. Its independent CLI tests cover byte-accurate identity,
sqrt-based gamma=2 output, invalid input and refusal to overwrite an output.
It is a **usable app-level consumer**, though **not independent adoption by an
outside application**. Do not claim that external adoption has occurred.

For the first library operation, accept **explicit scalar Levels math** over
a checked ROI, not "full Photoshop/GIMP compatibility":

```text
t = clamp((v - inputBlack)/(inputWhite - inputBlack), 0, 1)
adjusted = outputBlack + pow(t, 1/gamma)*(outputWhite-outputBlack)
output = v + maskStrength*(adjusted-v)
```

- Source sample types initially limited to `ubyte`, `ushort`, `float`.
  Integer samples map to [0,1] by dividing by 255/65535; float values
  use the supplied numeric domain. No hidden gamut/transfer function.
- A caller explicitly selects affected channels. Unselected channels
  retain their numeric values (normalized float output for integer input).
  In an ordinary straight-RGBA use, alpha stays unchanged only when
  the consumer leaves that channel unselected.
- An optional **editing-selection mask** has 0/128/255 weighted strengths
  (byte/255), **not** a NoData/validity mask or premultiplied alpha.
- Gamma/threshold/output bounds, nonfinite float handling, ROI bounds,
  empty and malformed input, failure before publication, independent pixel
  oracle and whole-versus-partitioned ROI equivalence are explicit contracts.
- Source and selected mask are borrowed. A **new, distinct
  `raster-d`-owned result** is published only after a successful call.
  Do not export the research `Into` signature as the first public API: it
  does not prove physical source/output nonalias.
- First result format under consideration is ROI-sized `RasterLease!float`.
  **That choice is provisional.** An RGB8 P6 consumer currently quantizes
  float to 8-bit independently; the public output type, quantization and
  memory budget must be reviewed rather than frozen by accident.
- No file I/O, PPM parser, imageio-d, CRS, STAC, satellite identity,
  general source/cache framework, scheduler, GUI or new pixel-owner type.

## Why this candidate rather than the previous three-component mapper?

| Evidence | Scalar Levels | Metadata-aware three-component mapping |
|---|---|---|
| First real end-to-end application work | Runnable P6 image-to-image CLI (#95); **no outside adoption** | Independent DUB research consumers, but no concrete non-test application adopted the complete metadata model |
| Core image semantics | Explicit tonal transform, selected channels, optional weighted editing mask, region | Immutable image-channel identification, explicit binding, physical calibration and separate validity |
| Minimal public dependencies | Already materialized `raster-d` raster, scalar parameters | Image semantic metadata, generations, calibrated sample policy, validation and ROI lifetime machinery |
| Ownership | Owned-result publish-on-success research prototype is exercised | Checked scoped Prepared/borrow research is deep, but published result and invalid-sample policy still open |
| Test evidence | 48 original sample/mask/layout cases plus 6 owned RGBA cases; real CLI DMD/LDC Release | Much broader researched lifetime/ROI cases; no need to discard them |
| Current priority | **First general image function** | Defer as a second, independently justified image-semantic capability |

This prioritization is **not** a claim that Levels is generally faster, that
metadata-aware mapping is unnecessary, or that a PPM CLI is a production photo
editor. There is no need for new C++ transliteration or further speculative
template specialization. R-IM-03e's `static if` mask dispatch currently
offers no demonstrated broadly favorable runtime result and is **not selected**.

## Minimal API *direction*, not frozen symbols

Prefer **one explicit owned-result operation**, with no separate public
caller-destination `Into` version at first. Maintain one shared image-domain
kernel internally. Keep `raster-d` responsible for layout, ROI and
resource ownership. A draft shape (names are **nonbinding**):

```d
// Sketch only — NOT an importable, supported imagery-d API.
Levels parameters = /* explicit finite settings */;
RasterLease!float result;
auto status = tryLevelsOwned(sourceView, region, affectedChannels,
                             parameters, optionalEditMask,
                             resultByteBudget, result);
```

**Proposed concrete output/residency contract (for review):** use one
`RasterLease!float` with exactly the source channel count, ROI-local size,
and physically **interleaved** float samples, regardless of input layout.
Integer input samples are mapped into [0,1] before scalar Levels math; float
inputs follow the existing declared nonfinite policy. The image operator
does **not** quantize back to 8/16-bit: a file encoder/consumer may choose
its own explicitly documented clamp/round policy. Alternative native-integer
result forms remain deferred until a consumer requires them.

The owner-controlled **mandatory `maxResultBytes`** argument caps exactly
the **new result's requested pixel payload**:

```text
newPayloadBytes = roi.width * roi.height
                * source.planeCount * float.sizeof
```

Validate source, ROI, channels, settings, mask, integer multiplication and
signed raster stride representation **before `malloc`**. For nonempty images:
`maxResultBytes == 0` or `newPayloadBytes > maxResultBytes` must return
a distinct `resultExceedsBudget` status without allocating or replacing
the old output; equality is accepted. The output pixel buffer is newly
owned by `raster-d`. On a returned kernel/import error, any partial private
temporary is discarded, and the old caller-owned lease remains unchanged.
No public caller-writable Into operation is necessary for this first slice.

**Accounting boundary:** the cap does **not** measure/limit:
`raster-d` backing-control and descriptor metadata, GC/allocator overhead,
retained source/selection-mask resources, any previous published result
which remains live until successful replacement, or application input/output
buffers (e.g. PPM). The **transient result payload live set** during a
successful replacement can include **old + new**; it is **not** a whole
process/RSS budget. This limitation is explicit and cannot silently be
labelled a general memory cap. Real allocation exceptions/OOM behaviour
also remain to be qualified separately.

**Existing code evidence:** the active [Levels P6 consumer Draft PR #95](https://github.com/alex-1974/imagery-d/pull/95)
has an exact-budget API prototype, source/mask/settings preflight before
allocation and negative old-owner preservation tests. These are **research
contracts**, not yet importable `imagery-d` production symbols. The additional mask-overload gate passed on #95 commit
[`db82bea30452ca5402465fb389218b7a4895953b`](https://github.com/alex-1974/imagery-d/commit/db82bea30452ca5402465fb389218b7a4895953b):
both [push CI](https://github.com/alex-1974/imagery-d/actions/runs/39318522229)
and [PR CI](https://github.com/alex-1974/imagery-d/actions/runs/39318529563)
completed 4/4 successfully (DMD 2.113.0 and LDC 1.43.0, Debug/Release).
These are correctness/build gates, **not** production performance approval.

**Mask-call-shape candidate now validated:** Draft PR #95 contains separate
unmasked and explicitly masked owned-result overloads. The P6 executable
uses the unmasked form; the independent consumer executes both for u8/u16/f32,
checking invalid `.init` masks, payload-budget failures and retention of the
prior owner on returned failures. The original Boolean-plus-view signature
remains on the research branch for compatibility with earlier evidence.
Neither the overloads nor their names are a frozen public API.
No `out RasterLease` replacement: a prior live owner must survive a
returned failure.

## Concrete admission gates — no additional broad research project

1. **Package/license — owner decision resolved, integration pending:**
   The owner explicitly confirmed **MIT** for every workspace repository on
   2026-10-19. This review PR adds the standard root `LICENSE`, documents
   MIT in `README.md`, and aligns existing `develop` research DUB manifests
   with `license "MIT"`. The future production `dub.sdl` MUST also declare
   MIT and ship the complete license text. **Until this PR is integrated,**
   the unchanged `develop` branch still lacks its root `LICENSE`; do not
   label the package published merely because the decision is settled.
2. **Simplify existing code:** reuse only the small tested Levels kernel and
   raster-owned output producer, not the stacked research/CI infrastructure.
   Preflight all ROI/parameters/mask/selection and checked size arithmetic
   **before allocation**; guard stride-to-`ptrdiff_t` conversion and define
   handling for recoverable allocation/import failures. Preserve the prior
   result owner on returned failure. Exceptions and druntime OOM `Error`
   require explicit documentation; do not falsely claim `nothrow`.
3. **Operation policy — output/pixel payload proposed above:** review the
   provisional ROI-sized `RasterLease!float`, interleaved output, mandatory
   new-result payload cap and old-result-overlap accounting. Still resolve
   public names and error classification, numerical tolerance,
   explicit colour-domain/alpha policy and retained-memory claims.
   The optional-mask overload *call shape* has a passing research gate;
   do not equate the payload limit to a whole-process memory budget.
4. **Small, ordinary consumer gate:** port the working P6 CLI and independent
   reference cases to import only the proposed production package. Maintain
   DMD/LDC Debug+Release, a negative lifetime/import check where applicable,
   and a lightweight end-to-end image ROI timing with correct comparable
   work. Report LDC Release performance without XPS thermal stress.
5. **Admission review:** after 1–4, issue a separate **Accepted/Rejected/
   Deferred** amendment with explicit API and performance verdict; only
   then promote the minimal package surface onto `develop`. Do not merge
   research-integration or the grandfathered stacked PRs wholesale.

## Existing evidence and repository consistency

- [M1 accepted image semantics](0002-image-semantic-core.md) and
  [M2 accepted source/cache architecture](0003-source-cache-pipeline-architecture.md)
  stay unchanged; neither requires satellite provenance for scalar Levels.
- [Levels independent consumer research #85](https://github.com/alex-1974/imagery-d/pull/85):
  48 cases and 240 complete region outputs with DMD/LDC qualification.
- [Real-image + owned-result Draft #95](https://github.com/alex-1974/imagery-d/pull/95):
  6 additional owned RGBA cases, 1,152 component observations,
  output-preserving failure, working P6 CLI, DMD 2.113/LDC 1.43
  exact-head [push](https://github.com/alex-1974/imagery-d/actions/runs/39273092575)
  and [PR](https://github.com/alex-1974/imagery-d/actions/runs/39273101318)
  jobs each 2/2 green at `3bb8bb444ef511d8100e7885135f87b2f5394416`.
- [R-IM-03e pragmatic rejection #94](https://github.com/alex-1974/imagery-d/issues/94):
  retain simple D math as starting point; no unjustified specialization.
- `raster-d` [v0.2.0 release](https://github.com/alex-1974/raster-d/releases/tag/v0.2.0)
  is now present; GitHub compare reports **identical source** against
  `2f2415851e45001df92ce56dad409f680684ba8d` used in the Levels
  research. The README at that pinned SHA still describes v0.2.0 as an
  unpublished candidate: this is historical/stale repository documentation
  relative to the verified 2026-10-10 release, **not** evidence that the tag
  lacks the tested APIs.

**Licensing correction:** the older experimental `dub.sdl` files declared
`BSL-1.0`; those declarations were inconsistent with the owner's MIT
policy. The three experimental manifests inherited by `develop` are changed
in this proposal without rewriting any historical commits. Other active
grandfathered research branches remain untouched; their metadata must be
checked and aligned on any subsequent production promotion. No assertion is
made that previously distributed third-party material can be relicensed
without its respective rights holder.

**Disposition until review:** this ADR is a **proposal**, not an
authorization to publish, create a speculative public source tree, or release.
The existing three-channel research selection is **proposed** to be superseded
only for the first M3 **qualification priority**, not erased or invalidated.
All active research PR bases/heads remain unmodified. This
`imagery-d` branch changes only the proposed ADR plus the separately
confirmed MIT `LICENSE`, README text and existing research-package license
declarations; it does not introduce or publish a production DUB package.
