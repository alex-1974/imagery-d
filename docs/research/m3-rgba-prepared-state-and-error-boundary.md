# M3 RGB source-over: Prepared state, error propagation and bounded ROI architecture review

**Date:** 2026-10-13. **Status:** research-only, no production API selected.
**Repo-write boundary:** ONLY `imagery-d`. `raster-d`, `color-d`, and
all other sibling repositories were inspected **read-only**; no proposal here
grants permission to edit them.

**Current branch:** `research/m3-rgba-layer-compositing`,
[Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73)
stacked on Draft #69, Issue #72.

## 1. Reviewed contracts: two different existing guarantees

The existing [imagery experimental four-plane compositor](../../experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d)
returns a `RgbaCompositeError`:
`none`, `invalidLayer`, `invalidEncoding`, `invalidRegion`,
`invalidOutput`, `invalidOpacity`,
`invalidPremultiplication`, `sampleFailure`, `quantizationFailure`.

It accepts a finite, caller-provided `opacity` in **[0,1]** and both
straight-encoded sRGB and tagged linear inputs; rejects encoded-premultiplied.
Structural/input-metadata and invalid linear-PM source sample failures are
preflighted before output mutation. In contrast, its own Ddoc explicitly says
unexpected sample failure or quantization failure in the **output loop may leave
earlier output pixels written**. Its source/destination nonoverlap requirement is
a **caller precondition**, not a proven physical alias check.

The released
[`raster-d v0.2.0 zipTransformInto`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/zip_transform_into.d)
performs *all* plane/shape/injective-destination/physical source-vs-destination
alias checks **before writing**, and supports any validated signed affine
layout with matching view dimensions. Its callback type is exactly:

```d
@safe pure nothrow @nogc T transform(T left, T right)
```

Because the public callback returns **only T**, there is no output status or
runtime callback context argument. A quantization-failure branch cannot
communicate `RgbaCompositeError.quantizationFailure` through this API, and
throwing is disallowed by `nothrow`. Any fallback to `SRgba8.init` (as in
the current research probe) is **not legitimate production error signaling**.
The `RasterZipTransformError` enum reports structural/alias failures,
**not image-domain pixel errors**.

**Discrepancy to resolve before API promotion:** the proven alias guarantees
of the fast packed executor are *stronger* than the older four-plane adapter,
but its per-pixel error and runtime-opacity expressiveness are *weaker*.
They are not interchangeable merely because successful outputs are byte-equal.

## 2. What D allows and what the public API exposes

D specifies that pure functions may read **immutable global state**, but not
mutable global state: [D function spec](https://dlang.org/spec/function.html).
Our fixed 0.37 LUT probe demonstrates that one runtime `shared static this()`
constructor can initialize an immutable 256×double lookup table, after which
the pure zip callback reads it with the required attributes.

That mechanism provides **one shared, program-lifetime, static sRGB8 table**,
not a user-selected prepared context. It must not be repurposed into a mutable
process-global `opacity` knob. In particular:
- a mutable global/thread-local current-opacity variable violates the
  intended `pure`/concurrency model;
- adding caller-owned data to a closure/delegate does not help the existing
  `zipTransformInto!transform` signature, which passes two pixel values
  and **no captured runtime context**;
- a template specialization per value only handles values known
  at compile time; it is not arbitrary floating-point runtime opacity;
- encoding opacity/context into each input/output **T** or carrying a
  per-pixel result/error flag changes the carrier, validation and image
  storage contracts; this may create full-image materialization and still
  does not give `zipTransformInto` an atomic failure channel.

A future explicit `scope` prepared image-domain value **could** hold
read-only decoded lookup state and caller-supplied opacity, but only a
consumer function that accepts that context can directly use it.
The workspace's [`DLANG_PRACTICES` scope/ownership and prepared-value
rules](../../.workspace/DLANG_PRACTICES.md) and [DIP1000 scope semantics](
https://dlang.org/spec/function.html#scope-parameters) apply to any borrowed
source, output or metadata it retains.

Crucially, imagery-d does **not** acquire access to `package(raster)`
execution pointers or physical-overlap machinery by creating that value.
No unsafe global, external `@trusted` cast, copied affine overlap
engine or sibling public-API edit is authorized.

## 3. An explicit failure-state matrix

| Condition | Four-plane research adapter today | Public raster zip with SRgba8 LUT | Accepted general contract? |
|---|---|---|---|
| Invalid layer/interpretation | classified before writes | not represented in SRgba8 callback | **NO** |
| Invalid runtime opacity (NaN, ±inf, outside [0,1]) | `invalidOpacity`, before writes | no runtime opacity | **NO** |
| Noncanonical linear-PM byte source | `invalidPremultiplication`, before writes | packed straight-encoded-only | **NO** |
| Invalid ROI/shape | classified before writes | invalid plane/shape before writes | category mapping requires design |
| Non-injective destination | no independent physical proof in adapter | `nonInjectiveDestination` before writes | only packed zip |
| Source/destination physical overlap | caller nonoverlap precondition | classified/rejected before writes | only packed zip |
| Unexpected read/write failure | `sampleFailure`; partial writes possible | structurally validated sampling, no pixel error return | **NO** |
| Quantization cannot store finite/rounded result | `quantizationFailure`; partial writes possible | callback can only return `SRgba8`, current **sentinel** | **NO** |
| Normal encoded-straight RGBA8, opacity 0.37, separate packed leases | checked error + successful output | checked structural and actual alias proof; exact colors in tested fixtures | **QUALIFIED restricted research** |
| Arbitrary runtime opacity / planar / linear premultiplied | accepted by four-plane path | not accepted by fixed callback | **NO** |

**Transactional caveat:** Do not silently strengthen the four-plane
`quantizationFailure`/unexpected-`sampleFailure` contract to
all-or-nothing writes. The current adapter explicitly permits a
partial destination on these two failures. Conversely, do not weaken
its existing preflight-before-write guarantees for invalid metadata,
ROI, opacity and noncanonical PM input.

## 4. Candidate designs, constrained to this repository

### A. Conservative fallback (already possible, no sibling changes)

Keep the existing checked four-plane imagery research function as
the complete *semantic reference*. It accepts runtime opacity and
classified errors and can use the already known per-input interpretation.
**But** its source/output nonoverlap stays a documented caller
precondition: do **not** call this a physical-alias-safe substitute.

Use the separately verified public zip+LUT fast path **only in its
explicitly narrow fixed-opacity encoded-straight packed domain**.
Selecting A or fast B behind one general API would change error/alias
behavior unless that API explicitly reflects the different guarantee
sets. For now keep them as **separate experiments**, not a single
public function with hidden branches.

### B. Prepared imagery-context prototype (eligible future imagery-only research)

An opaque, construction-checked internal prepared value can carry:
- immutable **byte-domain sRGB8 transfer** state with a defined
  ownership/initialization policy (2 KiB for the demonstrated table);
- a finite runtime layer-opacity value (no global mutation);
- explicit input encoding/association and destination representation;
- source/view and metadata borrows held only for a scoped call or
  by an explicit retained owner (no borrowed value escaping);
- a precise error class and provenance linking preparation to the
  source generation and mode.

**Research-only execution:** until an existing suitable *public*
raster execution operation is demonstrated, a checked
imagery-local pixel loop is the honest fallback, without claiming
zip's physical alias proof. No new raster internals, trust cast or
general prepared-handle public API.

Performance must include **preparation, mode selection, fallback
frequency, ROI processing and peak scratch**. A prepared token should
be justified by repeated ROI/map work, not by hiding an unchecked
fast path. Existing M3.2 scoped-prepared metadata research supports
**in-call borrowed preparation**, not globally persistent
source-bound prepared owners.

### C. Scratch-then-commit (possible future error-atomic mechanism)

Compute into a bounded caller-provided scratch raster, prechecking all
per-pixel color/quantization conditions. This can classify all errors
before target mutation; only after success would a separate commit
copy pixels to the caller target.

**Important gaps:** the present public raster zip/copy APIs do not
expose a standalone generic *prewrite physical overlap query*
independent of doing a transform/copy. A scratch-then-commit plan
that only checks scratch-vs-destination **does not** enforce
original input-vs-output disjointness. It also changes memory
and timing requirements and must handle destination write failure
during commit. Do not assert that C is already a complete
production-safe solution.

### D. Hypothetical contextful checked zip (NOT a requested sibling change)

A semantic interface with scoped context and a checked callback could
combine prepared state, per-pixel error reporting, alias validation and
fast row execution. That is a **research requirement gap**, not a
design to implement in `raster-d` without explicit cross-repo
approval and its own ABI/API/benchmark proof. Do not hardcode this
future interface into `imagery-d` before its costs and failure
semantics have been qualified.

## 5. Small offset ROI evidence — independent measurement gate

The [packed public-zip LUT experiment](../../experiments/m3_rgba_layer_compositing/lut_packed_zip/source/app.d)
now accepts `--roi-side=N` (positive integer),
selecting `Region2D(7,11,N,N)` within the full retained source
and destination. `--partial` and `--roi-side` are mutually
exclusive. Old `whole` and near-full `partial` modes remain
unchanged. Tests compare **every destination pixel**,
including unmodified sentinel values outside ROI, and still
attempt actual left/right physical overlap.

The runner
[`run_m3_rgba_lut_zip_xps.sh`](../../tools/research/run_m3_rgba_lut_zip_xps.sh)
now supports `--micro`:
- sources/targets retained at **512×512**, unchanged from large-ROI
  host allocation; square ROI sizes **16², 32², 64², 128²**;
- mixed and fully transparent-with-hidden-RGB input patterns,
  compact and row-padded packed layouts;
- **16 independent OS processes** × **9 alternating A/B rounds**
  × **32 complete ROI calls per treatment per round**;
- CPU, source SHAs, packed RSS, stdout CSV, stderr/resource logs and
  per-case SHA-256; **no sibling modification**.

This isolates real small-region repeated **zip invocation costs**
and SIMD/dispatch amortization more honestly than the previous
~95–98% partial-image ROIs. However, the harness still retains
and verifies entire 512² buffers **outside** the timed section,
so whole-process wall time and RSS must not be confused with a
single 16² tile kernel. The extra 16² case is useful for
detecting when per-call fixed costs dominate.

A short `--micro-smoke` runs 16²/32², both packed layouts
on 96² backing and is part of the LDC 1.43 CI gate.
The normal `--smoke` and native full-size runner remain
separately available.

**Required native evidence:** ratios from real XPS
LDC1.43 (same tagged raster-d/color-d v0.2.0), per-case
median and round spread, verified output/alias/GC, and
no mixed data set size changes between direct and LUT.
Do not infer the real small-ROI speed ratio from
the previous 512²/2048² full-image results.

## 6. Next decisions after native micro ROI and context/failure probe

1. If the fast path remains beneficial for small ROIs,
   qualify image-layer *scoped prepared* runtime opacity
   against the **same** pixel oracle and compare its
   whole-operation cost with a public zip treatment,
   **explicitly preserving their different alias/error contracts**.
2. If the fast path is not favorable for 16²/32², compare a
   prepared context's setup/dispatch and avoid
   specializing extremely small calls.
3. Decide what `quantizationFailure` means for production
   output state (partial vs scratch-atomic) and prove it with
   deliberately nonstorable inputs before any API exposure.
4. Require lifetime negatives (DIP1000, scope escape),
   cross-compiler codegen, GC/native peak and realistic
   repeated-viewport/streaming evidence before promoting
   a persistent prepared RGBA session.

**Disposition:** Research-only; no production symbol,
new sibling API, cross-repo write, merge, or decision
to switch `color-d`/raster-d. OPEN/DRAFT PR #73
stays stacked on Draft #69.
