# M3 RGBA — single traversal of canonical-PM bytes in private staging

**2026-10-16 · Issues #74/#75 · Draft PR #73 · Research-only proposal under CI.**
**Not an admitted production API, validated optimizer or completed XPS result.**

## Why this bounded follow-up exists

Independent XPS full-result pairing at measured
`01f02c0a5d52005620d5dabcf9e22aaf9e0de337`, archived in
[m3-rgba-preflight-xps-independent-results-2026-10-16.md]
(m3-rgba-preflight-xps-independent-results-2026-10-16.md),
found valid-input duplicate-ROI-PM preflight slowing
linear-PM mixed **+6.9%** and transparent **+20.9%**
(cohort medians of case-specific seven-round paired ratios).
**18/20** linear-PM cases crossed the registered +5% review
trigger, while encoded-straight had **1/20**. Additional
cost was typically about **5–7 ns/pixel**, close to the
independently timed extra PM scan.

The correctness gate still requires rejecting known
invalid canonical linear-PM input **before the first
physical scratch malloc**. Simply removing early preflight
would violate that tested contract. Omitting the second
check with only an `@safe` read view would also lack an
immutable-source proof. Borrowed `RasterView!ubyte`
does NOT prevent a separately retained writable lease from
changing the same backing between preflight and consumption.

## Research design: preflight + fused checked emission

Keep the existing `@safe nothrow @nogc`
`tryPreflightRgbaSourceOverPrepared`, executed before
any output scratch allocation. It validates the entire
source ROI's canonical PM RGB<=alpha bytes (when relevant)
as well as geometry/encoding/context.

The original, fail-before-first-caller-write
`tryCompositeRgbaSourceOverPrepared` is retained with
the same semantic contract. Its entire ROI PM scan remains
before the first write for a supplied destination. A
new **separate** and explicitly research-only
`tryCompositeRgbaSourceOverPreparedStagedChecked`
validates metadata/output shape and then, as each actual
source pixel is read into *local* `SRgba8` values for
color-d compositing, checks each current linear-PM
RGB<=alpha **on those already-loaded bytes**.

This eliminates the second independent PM ROI traversal;
it does **NOT** replace or weaken the check on each
pixel that is actually consumed. Both paths call the
same templated private `runPreparedRgbaPixels`
mathematical/quantization/write loop, with compile-time
selection of either:
- original separate all-ROI PM preflight, then no extra
  PM check in its emission loop; OR
- separate all-ROI PM preflight **before scratch malloc**
  in the owned consumer, and compile-time PM comparisons
  at the individual pixel use sites (no second scan).

The staged-checked function **MAY leave a partly
written destination on late invalid input or write
failure**. Therefore it must only be used on a **new,
privately owned scratch RasterLease** never made visible
to the caller before complete success; error destroys
that scratch, with an empty `RasterLease!SRgba8`
publication result. A valid complete packed output is
published only after the second packed allocation,
write completion and import. Ordinary resource failure
unwind remains separately tested. The experiment does
not introduce a public unchecked entry or silently
turn a caller-supplied target into a transactional API.

The consumer-local
`tryCompositeOwnedPackedResearch(..., true, true)`
is **strictly opt-in for research**. Its first boolean
still controls the old-versus-early source preflight
benchmark; `useStagedChecked=true` demands the early
preflight. The normal current `false` path and the
original historical `--owned-preflight-bench`
are preserved, so prior measurements are not silently
relabelled or reinterpreted.

## Safety/correctness qualifications

Required in the independent DUB source tree, using
only public pinned raster-d/color-d dependencies:

1. **432 independent two-layer RGBA scenes**, both
   physical input layouts, three color/association
   interpretations, several opacities and both ROI
   positions: every fused produced `SRgba8` pixel
   must equal the old owned result and the existing
   independently oracled caller-owned result.
2. Explicitly preflight one valid linear-PM ROI,
   **then mutate the very last ROI input pixel** via
   the same genuine public retained raster owner
   so `r=255,a=0`. The subsequent staged-checked
   loop must return `invalidPremultiplication`
   before using those invalid local bytes; only
   private scratch may have partial writes and
   **no packed owned lease is ever published**.
3. Existing native fail-before-malloc, actual
   first/second pixel ENOMEM, pre/post-commit
   raster import disposition, Tier-P 8N/4N and
   432-scene baseline gates remain mandatory;
   none of those guarantees is inferred from
   a faster loop.

The fused per-pixel comparison protects the actual
byte values consumed even if the source changes after
the earlier preflight. It is NOT a torn-read,
thread-safe snapshot or atomic four-channel image
claim; unsynchronized concurrent writes remain an
unresolved external contract.

## Performance qualification, **not yet measured**

New independent `--owned-fused-bench` consumer
mode times three **entire physical owned output
productions**, rather than subtracting a synthetic
standalone preflight:

1. `owned_old_order`: scratch allocates, then
   baseline destination-compositor preflight.
2. `owned_early_preflight`: early check before malloc
   **and** baseline second PM ROI scan (slow control).
3. `owned_fused_checked`: early check before malloc
   plus local PM checks on each actual pixel during
   emission (no second traversal).

A dedicated immutable XPS runner
`tools/research/run_m3_rgba_fused_xps.sh`
and independent
`tools/research/summarize_m3_rgba_fused_xps.py`
retain the original 8-case smoke / 40-case full matrix,
rotated seven-round pairing, both planar/interleaved and
encoded-straight/linear-PM interpretations, mixed vs
transparent patterns, ROI sizes 16–256,
cross-layout canonical checksums,
per-thread GC observations, compiled executable bytes,
pinned git SHA/environment and original SHA-256 manifest.
Only the new benchmark executable's data may be used to
claim fused/legacy or fused/double performance.

The summarizer requires all expected raw files,
source/compiler pins, complete stage ordering and
literal PASS trailer, independent binary and CSV hashes,
all 40 canonical checksum comparisons, and emits
full-call absolute ns/pixel, **same-round paired**
ratios/differences, extrema and GC deltas. It must
pass its realistic self-test, GitHub four-compiler
smoke and pinned LDC1.43 snapshot smoke before
any numeric performance conclusion.

**Decision trigger:** if the full same-host paired
XPS median fused/old ratio is still >1.05 for
important linear-PM workloads, report regression and
stop; do not rationalize a weakened contract as speed.
Even ratios <1.05 remain workload/CPU-specific and
are NOT a production speed guarantee.

## Boundaries left unresolved

- Selection of output form A (caller-owned target)
  versus B (complete-on-publication owned result)
  by a real downstream consumer.
- Caller-provided destination physical noalias
  and partial-write semantics.
- The owned result's full GC Error-level OOM and
  physical RSS bounds; Tier-P tracks only requested
  RGBA pixel payload.
- Concurrent source mutation/true immutable ownership,
  threading and cancellation; neither `@safe`
  nor this fused stage certifies thread-safe snapshots.
- Independently packaged public code/Ddoc, DMD and LDC
  API/generator gates, numbered accepted ADR.

**Research disposition: ADAPT the single-traversal
staged checked mechanism only if CI and XPS data support
it. DEFER production API, merge and release.**
