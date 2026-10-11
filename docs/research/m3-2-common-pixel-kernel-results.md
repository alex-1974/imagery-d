# M3.2.10 — Common checked pixel kernel: research qualification

**Status:** Research-only refactor with one shared checked execution
kernel. Initial four-toolchain contract matrix **PASS**; final
error-precedence/codegen recheck and controlled Dell XPS speed-attribution
remain separately qualified. No public API or production admission.

**Repository:** `imagery-d` only.  
**Branch:** `research/m3-2-common-pixel-kernel`, stacked on M3.2.9.  
**Issue:** [#42](https://github.com/alex-1974/imagery-d/issues/42).  
**PR:** [#43](https://github.com/alex-1974/imagery-d/pull/43).  
**Baseline evidence:** [M3.2.9 XPS result](m3-2-prepared-semantic-map-xps-results.md).

## 1. Motivation

M3.2.9 observed substantial XPS gains for the **prepared research path**,
including 256 bands / 8×8 at median paired ratios 1.343×
(interleaved) and 1.474× (planar with validity). That experiment had a
serious **attribution confounder**: the prepared pixel loop was a
separate implementation, and LDC generated different inlining
(especially for validity/sample access). At just 3 bands and 64×64
pixels the prepared route was faster by 12–16%, which cannot
plausibly be explained by removing a single linear identity scan
alone. The 1.343×/1.474× ratios do **not** isolate preflight costs.

Workspace DESIGN_PRINCIPLES §19.1 supports preparing invariant state
once when reuse is real, but also demands equivalent visible
semantics for the ordinary one-shot fallback.

## 2. One and only one checked execution body

The research-only M3.2.2
`m3_2_channel_metadata.contract.mapComponentsInto` still performs
its original validation **in the original order**:

1. Intrinsic metadata count.
2. Every M1 image/intrinsic semantic channel identity.
3. Explicit three-channel binding in range and distinct.
4. Destination exactly three planes with matching width/height.
5. Independent single-plane validity representation.
6. Required finite physical calibration, only for physical mode.

After that preflight, it derives the same explicit three indices and
the three scale/offset values and invokes the shared function.

The prepared M3.2.9 `PreparedSemanticMap.mapInto` instead:
1. Requires the privately created, scope-bounded, truly immutable
   verified source and already validated three-channel binding
   with retained scalar calibrations.
2. Checks **each destination** has exactly three planes and the
   current ROI extent.
3. Invokes the **identical shared function**.

Both paths call the same
`m3_2_channel_metadata.contract.researchExecuteCheckedPixels`,
explicitly marked `pragma(inline,false)` to make the boundary
auditable in optimized compiler machine code.

That kernel alone contains the implementation of the image-wide
sample loop: checked optional validity reads, three checked source
sample reads, explicit `stored*scale+offset` when physical, a
zero result for invalid pixels under the **test-only** mask policy,
and checked destination writes. No allocation, unsafe pointer
arithmetic, `@trusted`, assumed colour conversion, or new owner
were introduced.

The return contract continues to return
`SemanticMapError.sampleAccessFailure` upon any checked sample
or output failure. Like M3.2.2, successful preflight does not imply
transactional rollback if an output sample write later fails.

**Numerical note:** M3.2.2 formerly loaded the selected immutable or
caller-owned calibration values from intrinsic metadata inside the
pixel loop; now its fully checked entry captures each selected
scale/offset once as a scalar value before the same loop.
For already-immutable metadata the values are invariant. With
**caller-mutable `const` metadata and concurrent alias mutation**,
this is a possible behavioral difference during a long-running
operation and must be considered under an explicit data-race and
mutation contract before any production promotion. This experiment
does not license synchronized mutable metadata aliasing.

## 3. Temporary research-only module boundary: NOT a public API

D module-level `private` is not callable from the existing separate
M3.2.2 and M3.2.9 research modules without a different module
organization. Therefore the shared **noninline execution symbol**
is reachable through a clearly named *research-only internal adapter*
in the M3.2.2 experiment module. It accepts prevalidated scalar
arguments; `@safe` memory safety does **not** itself prove image
semantic identity. Outside callers must NOT be offered this adapter
as a public imagery package API.

This is a deliberate research boundary to isolate machine-code
effects. A production candidate must instead use one of:
- module reorganization so both one-shot and prepared entry points
  call a **private** implementation; or
- an unforgeable scoped execution capability with its factory in
  the same tightly restricted module and no public raw execution
  bypass.

A Boolean `validated=true` parameter or positional aggregate that
can be fabricated by an external caller is **not** acceptable.
All existing M3.2.6 and M3.2.9 negative DIP1000/constructor fixtures
remain mandatory.

## 4. Qualification and regression tests

The first [four-compiler CI run #38167056342](
https://github.com/alex-1974/imagery-d/actions/runs/38167056342)
passed **4/4 compiler jobs** on DMD 2.111.0, DMD 2.113.0,
LDC 1.41.0 and LDC 1.43.0, including:
- pre-existing M3.2.6 debug/release correctness and all six
  negative lifetime/type/forgery builds;
- M3.2.9 prepared debug/release pixel equivalence, three
  prepared owner/metadata/forgery compile-negatives;
- three-path synthetic consumer oracle across planar/validity,
  interleaved/no-mask and multiple channel/ROI counts;
- LDC 1.43 complete evidence-runner smoke and a codegen audit
  checking for the shared kernel callsites.

A subsequent gate extends the exact oracle with one-shot
**error-priority and no-write-on-preflight-failure** tests:
when metadata identities and destination are both invalid,
identity failure must win; when destination and calibration are
both invalid, destination error must win. A destination sentinel
must not be modified upon a failed preflight.

The new `tools/audit_common_kernel.py` parses the actual optimized
disassembly of the **timed binary**, requiring one shared noninline
definition and calls from both one-shot and prepared paths.
The `qualify_prepared_xps.sh` runner now treats this codegen
check as mandatory, not an optional hint. A passing hosted script
run demonstrates the harness functions; cloud elapsed times are
**not** XPS evidence.

## 5. XPS evidence needed

From `libs/imagery-d` on the Dell XPS:

```bash
git fetch origin
git switch research/m3-2-common-pixel-kernel
git pull --ff-only origin research/m3-2-common-pixel-kernel

COMPILER=ldc2 REPEATS=5 ROUNDS=12 ITERATIONS=24 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_prepared_xps.sh
```

The script records source and dependency SHA/states, CPU/governor
and compiler versions, all expected negative gates, exact pixel
oracles, binary SHA-256, raw paired/tripled consumer timing
distributions, and compressed disassembly plus a
`common-kernel-audit.log`.

The local `raster-d` may differ from `v0.2.0`; the script records
this explicitly and does **not** checkout/reset/clean/write another
repository. The measured XPS performance must be compared **against
the same common-kernel source revision**, not by treating prior
M3.2.9's different-kernel values as isolated preflight effects.

## 6. Admission boundary

This work supplies a controlled experiment, not a new public
`imagery-d` function. Before admission: actual XPS data and
codegen, wider numerical/error tests, explicit handling of
caller-mutable metadata semantics, removal of the research-only
raw execution adapter from the public import surface, and a
deliberate integration PR. Do not merge stacked research wholesale
to `develop`; keep evidence, negative tests and issue/PR lineage.
