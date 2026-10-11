# M3.2.9 — Prepared semantic mapping: architecture and compiler evidence

**Status:** Research-only semantic contract, exact pixel oracle, lifetime/anti-forgery gates and three-way harness **QUALIFIED**. **Observed XPS measurements now audited**: [M3.2.9 local-state XPS evidence](m3-2-prepared-semantic-map-xps-results.md). Production admission, release API, isolated optimization attribution and pinned-release performance remain **OPEN**.
**Date:** 2026-10-11.  
**Branch:** `research/m3-2-prepared-semantic-map` (stacked on
`research/m3-2-consumer-amortization`).  
**Issue:** [#40](https://github.com/alex-1974/imagery-d/issues/40);
**PR:** [#41](https://github.com/alex-1974/imagery-d/pull/41).

## 1. Why a prepared semantic capability?

[M3.2.8's independently reviewed Dell XPS measurements](
m3-2-consumer-xps-results.md) established that using a validated
immutable ROI saves about 8–10% for **256 channels / 8×8** mapped
image operations, but has limited or unstable benefit at larger
pixel regions. The original mapping kernel still repeats the
O(channelCount) image/intrinsic semantic-ID comparison and evaluates
selected three-channel binding/calibration on **every** operation.

Workspace `DESIGN_PRINCIPLES.md` §19.1 encourages preparing invariant
state once when its reuse is meaningful, while requiring equivalent
visible semantics and empirical qualification. We therefore
investigate a *prepared channel-binding capability*, not a new
image owner, allocator or public execution API.

The accepted `imagery-d` ADRs 0002/0003 continue to define the
domain: one common-grid raster, distinct validity, explicit
image-channel identity and radiometric interpretation; `raster-d`
retains the backing and performs checked sample access; no assumed
colour binding, NoData/alpha conflation or implicit conversion.

## 2. Research contract

```text
RasterLease!float (retained elsewhere)
  |   immutable M1 and intrinsic metadata
  v
ValidatedImmutableImage factory
  -> O(channels) ID/grid validation ONCE
  |
  +-- tryPrepareSemanticMap(explicit ColourBinding, stored/physical)
        -> O(1) three-index/calibration checks
        -> PreparedSemanticMap (borrowed, unforgeable, no allocation)
             |
             +-- tryRoi / nested tryRoi:
             |    O(1) semantic metadata; raster/validity ROI bounds checked
             |
             +-- mapInto(destination):
                  destination 3-plane, size checked on EACH call
                  mask/sample reads checked
                  destination writes checked
                  O(width*height) pixel operation
```

The **private explicit constructor** prevents outside callers from
building a false already-validated marker. `.init` is an inert,
rejecting capability. `tryPrepareSemanticMap` accepts only an
already-verified immutable image; `const` over mutable descriptors
does **not** qualify. The prepared value contains that transitively
borrowed image (with separate raster and optional mask backing), the
three chosen indices, and scale/offset values copied at preparation.

The prepared capability can derive child and nested ROIs while
retaining exactly the same **immutable** band semantics and selected
binding. It cannot extend raster/metadata ownership or safely
outlive the source owner. It also cannot assume source pixels are
immutable merely because metadata is immutable: the checked pixel
reads occur on every mapping.

The operation does **not** allocate, does not require `@trusted`,
and its declared hot path is `@safe nothrow @nogc`.
It still checks every destination's shape and preserves checked
raster/validity sample access. Invalid to zero is the original
**experiment-only policy**, not a public NoData/alpha contract.
Partial destination changes remain possible if a sample write fails
after successful preflight, as in the M3.2.2 one-shot operation.

The `DeclaredColour` field is carried by the binding but
does **not** perform colour-space conversion, consistent with the
existing M3.2.2 semantic contract.

## 3. Positive and negative correctness evidence

**First passing run:** [#38164569773](
https://github.com/alex-1974/imagery-d/actions/runs/38164569773).
The four compiler jobs on DMD 2.111.0 / 2.113.0 and
LDC 1.41.0 / 1.43.0 all passed the original M3.2.6 debug/release,
DIP1000 negative and external forgery gates **plus** the new
prepared mapping exact-oracle and negative gates.

Research fixture tests cover:

- calibrated **physical** values and uncalibrated **stored** values;
- channels 3/17/64/256; planar and pixel-interleaved backing;
  optional independent validity mask;
- whole-image and nested ROIs; semantic metadata reused between
  them, with independent exact-value checks;
- comparing the conservative one-shot mapping, existing validated
  ROI + one-shot mapping, and prepared mapping against an
  independent synthetic scalar oracle;
- default-inert state, invalid ROI/destination, duplicate/out-of-range
  channels, missing calibration and NaN calibration;
- expected compile-negative escape from a local raster owner,
  and expected denial of outside-module capability forgery.
  The additional local immutable-descriptor escape fixture is now
  compiler-rejected on all four toolchains.

A compiler diagnostic must genuinely concern the expected forbidden
source form; unrelated DUB/syntax errors do not count as successful
negative proofs.

## 3a. Final three-way toolchain qualification

The complete [CI run #38165027582](
https://github.com/alex-1974/imagery-d/actions/runs/38165027582)
passed **4/4 jobs**:

| Compiler | M3.2.6 previous lifetime checks | M3.2.9 debug/release exact map oracle | Three new expected compile negatives | Three-way mapped consumer smoke |
| --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | PASS | PASS |

The **three** new whole-source compile-negative fixtures intentionally
reject borrowing a locally owned raster, borrowing local immutable
channel metadata, and attempting to construct the private prepared
capability from outside its defining module. All rejections were
checked against expected compiler diagnostics rather than mere
non-zero DUB exit status.

The final boundary-case extension was requalified in
[GitHub Actions #38165284478](
https://github.com/alex-1974/imagery-d/actions/runs/38165284478):
**all four compiler jobs PASS again**. The extra positive fixtures
show that a structurally valid **single-channel** image cannot acquire
a three-component binding and that **infinite** calibration is
rejected during preparation (in addition to existing NaN and missing
calibration cases). The LDC 1.43.0 hosted evidence-runner check
also completed successfully.

The LDC 1.43.0 job additionally invoked the complete
`qualify_prepared_xps.sh` runner under tiny hosted-CI sample settings
(one process, two rounds, two mapping calls per round). Its Python
analyzer accepted **48 complete matched triples**, each with all
three mapping modes, distinct measurement slots, identical
iteration counts and matching output checksums. It generated
validated raw CSV, per-case summary and binary provenance files.

**This is functional proof of the harness, not evidence of a
performance ratio**: the tiny cloud workload is non-gating for
performance. The final XPS evidence and compiler machine-code
comparison must be measured independently.

## 4. Three-way controlled workload

The M3.2.8 synthetic image consumer was extended *optionally* to
measure the three pathways with equal source pixels, selected channel
binding and caller-owned three-plane destinations:

1. `revalidated_image`: the full conservative image ROI and original
   `mapComponentsInto`;
2. `verified_immutable_image`: immutable validated ROI, followed by
   **the same** original `mapComponentsInto`;
3. `prepared_semantic_map`: binding/calibration prepared **once**
   outside the timed pixel loops; reuses verified ROI + cached
   semantics inside a separate research pixel mapper.

Exact per-pixel oracles run over 3/17/64/256 source bands,
8×8/32×32/64×64 output regions, planar+mask and interleaved
without mask. Paired/tripled measurement order changes between
rounds; output checksums must agree across all three modes.
The existing two-way M3.2.8 CLI remains available unchanged.

The full comparator reports `prepared_map` rows (channel count,
ROI side, storage mode, validity, round, slot, execution route,
iteration count, elapsed nanoseconds, checksum). Setup records
include the original `caller_borrow_validate`,
`already_immutable_validate`, `snapshot_and_validate` and,
when using the new three-way variant, the
`prepared_binding_only` cost.

The stdlib Python analyzer refuses incomplete triples, unequal
iteration counts, mismatched checksums, and duplicate execution
slots. It emits raw validated data, median/MAD per case, and paired
ratios rather than assuming the faster result.

### XPS reproduction

From `libs/imagery-d`:

```bash
git fetch origin
git switch research/m3-2-prepared-semantic-map
git pull --ff-only origin research/m3-2-prepared-semantic-map

COMPILER=ldc2 REPEATS=5 ROUNDS=12 ITERATIONS=24 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_prepared_xps.sh
```

The runner records the compiler, image/raster Git commits, both
worktree statuses, CPU governor/affinity, build/negative-test logs,
timed binary SHA-256, raw process logs, per-case median/MAD and
disassembly. It does not checkout, clean, reset or write **any**
sibling repository. If the raster checkout is not the exact
released `v0.2.0` tag, the run is **measured local-state evidence**,
not pinned-release evidence.

Hosted runner timings, including full end-to-end script smoke,
are **only a harness gate**, never qualified XPS performance data.

## 4a. XPS evidence update (subsequent operator run)

The operator's `prepared-20261011T185500Z.tar.gz` XPS archive was
independently audited and is documented in
[M3.2.9 — Dell XPS prepared mapping results](
m3-2-prepared-semantic-map-xps-results.md).

The archive contains **4,320** full pixel-mapping timings,
**1,440** complete, matched, checksum-equal three-path comparisons,
balanced call order and successful local LDC 1.41.0 debug/release
and compiler-negative gates. At **256 channels, 8×8**, the prepared
research path has median paired ratios of **1.343×** for interleaved,
unmasked and **1.474×** for planar+validity over the original one-shot
route. With **256 channels, 64×64**, the corresponding observed ratios
are **1.073×** and **1.172×**.

**Crucial distinction:** the prepared prototype includes a
**different pixel execution kernel**. The XPS disassembly shows
additional per-pixel inlining differences, including the one-shot
mapper's `ImageView.tryValidity` call being inlined away in the
prepared kernel. The measured benefit therefore does **not**
quantify the effect of cached semantics alone. Even the three-channel
64×64 cases show ~12–16% gains; this is further evidence that
codegen differs for more than O(channels) validation.

Prepared-binding-only setup was tentatively ~25–29 ns across
channel counts; two `.idup` snapshots plus factory are much more
costly. Compiler hoisting, GC effects and limited timer resolution
leave the exact reuse break-even **unqualified**. XPS used the
locally audited older `raster-d` commit rather than precisely
`v0.2.0`; this is measured-state research, not pinned-tag release
qualification.

## 5. Critical production blocker: single execution kernel

This experiment duplicates the straightforward M3.2.2 pixel loop
inside the research-only `PreparedSemanticMap.mapInto` in order to
remove its repeat preflight without weakening `@safe` lifetime
or exposing unchecked generic raster pointers.

**Do not promote duplicated pixel kernels to production as-is.**
A future production candidate should factor the M3.2.2 one-shot
and prepared entry points through **one audited private execution
kernel** after each entry point has established equivalent
preconditions. The M3.2.2 ordinary one-shot path must remain an
obvious, complete fallback for caller-mutable `const` metadata.
It must be impossible for an outside caller to forge the
already-validated tag. Failure classification, numerical results,
validity, destination checks and sample-access safety must match
for all admitted inputs.

Subnormal/NaN/Inf floating sample behavior, aliasing,
write-after-error, and full-domain numerical equivalence have not
yet been exhaustively proven beyond this exact synthetic corpus.
No public name, metadata allocator, or checked-storage contract
is frozen here.

## 6. Decision state

**Qualified so far:** safe preparation model, immutable metadata
invariant, scope-bounded source/view ownership, selected three-band
binding checks, exact synthetic oracle correctness and first four-
toolchain compiler matrix. Three-way mapping benchmark harness is
provided for direct measurement.

**Now observed:** full local XPS timing distributions and source-level
codegen differences, with no claim that the entire speedup comes from
one-time metadata binding.

**Still pending:** a **common audited execution kernel** shared by
M3.2.2 one-shot and prepared mapping; repeatable XPS comparison
isolating only the preflight change; anti-hoist/GC-aware setup
amortization; optional exact pinned `raster-d v0.2.0` reference; and
public API admission. Preserve M3.2.7/8 evidence independently.
