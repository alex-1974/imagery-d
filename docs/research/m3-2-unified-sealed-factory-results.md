# M3.2.12 — One immutable verification factory for sealed semantic mapping

**Status:** **4/4 compiler correctness, lifetime and checked-token
anti-forgery CI PASS**; optimized LDC common-private-kernel audit
**PASS**. The subsequent Dell XPS run is independently audited in
[M3.2.12 unified-factory XPS results](m3-2-unified-sealed-factory-xps-results.md):
small/high-band synthetic ROI mapping remains faster and the
second once-only channel-ID scan is eliminated. **Release-grade
preparation break-even, wider consumer/numerical behavior and
public API admission remain OPEN**.
Stacked research [PR #47](https://github.com/alex-1974/imagery-d/pull/47).

**Issue:** [#46](https://github.com/alex-1974/imagery-d/issues/46).
**Base:** `research/m3-2-sealed-execution`, [PR #45](
https://github.com/alex-1974/imagery-d/pull/45).
**Measured prior baseline:** [M3.2.11 XPS results](
m3-2-sealed-execution-xps-results.md).

## 1. Problem and source-derived requirement

M3.2.11 closed a real capability bypass: the
`researchExecuteCheckedPixels` scalar kernel became D module-private
and only `ResearchCheckedExecution` could call it. That introduced
a **second O(channelCount) channel-ID scan** when creating the sealed
executor from an already validated immutable image.

Its local XPS experiment measured at 256 bands / 8×8:
- conservative versus sealed prepared mapping **1.3074×**
  interleaved and **1.2667×** planar/masked, paired medians;
- `sealed_execution_validate_and_prepare` **114 ns**, versus
  **91 ns** for the earlier `already_immutable_validate` factory;
- two `.idup` copies + image factory **7,141 ns**.

These numbers describe M3.2.11's **different source revision**,
and are not new M3.2.12 performance results.

## 2. Internal module boundary

```text
              caller-held RasterLease
                   + truly immutable M1/intrinsic arrays
                                 |
                                 v
       m3_2_channel_metadata.contract  (single D module)
              |
              +-- tryResearchVerifySemanticImage(...)
              |        O(channelCount) identity validation ONCE
              |        M1 image/validity geometry validation
              |        private ResearchVerifiedSemanticImage ctor
              |
              +-- verifiedImage.tryPrepare(explicit binding, values)
              |        three distinct indices + finite calibration
              |        O(1) / NO second identity scan
              |        private ResearchCheckedExecution ctor
              |
              +-- original one-shot mapComponentsInto(...)
              |        original full repeat preflight
              |        for mutable-const metadata consumers
              |
              +-- PRIVATE shared noninline checked pixel kernel
                    validity, reads, radiometry, writes
```

The experimental M3.2.6 wrapper `ValidatedImmutableImage` in
`m3_2_verified_roi.contract` now holds the
`ResearchVerifiedSemanticImage` token rather than a parallel
independently verified `ImageView + ids + intrinsic + bool`.
`tryMakeValidatedImmutableImage` delegates its error-distinguished
factory to the *same module that constructs the sealed executor*.

The M3.2.9 `PreparedSemanticMap` wrapper calls
`image.verified_.tryPrepare(binding, values, error)`.
A `const(T)[]` alias to caller-mutable metadata **does not
qualify** for the verified semantic token: the factory accepts
`immutable(ChannelDescriptor)[]` and
`immutable(IntrinsicChannel)[]` only.

The private executor is the same checked `@safe nothrow @nogc`,
non-owning, destination-checked implementation as in M3.2.11.
Ordinary One-shot still scans every descriptor on each call.
ROI derivation preserves source/validity/metadata borrows with
`return scope`, and neither factory secretly copies metadata.

## 3. Compatibility and security gates

The M3.2.6 research-facing method/constructor signatures and error
classification are preserved:
- `descriptorCountMismatch` for image/intrinsic metadata length;
- `identityMismatch` for intrinsic versus image semantic ID;
- `imageViewFailure` for invalid image plane/validity grid;
- `none` on success.

The prior **M3.2.6 negative external-forgery test had become stale**
after its private constructor changed from two inputs to one.
It has been updated to call the **exact current one-argument
private constructor**, using a `ResearchVerifiedSemanticImage.init`
token. The gate must reject *privacy*, not an arity mismatch.

Additional M3.2.12 negative evidence requires an outside module
to fail constructing `ResearchVerifiedSemanticImage` with the
**exact three arguments** of its private constructor. The original
M3.2.6 four borrow-escape, mutable-const metadata, M3.2.9 owner,
metadata, and forged-prepared, plus M3.2.11 raw-kernel/capability
denials remain in the four-compiler CI matrix.

The shared semantic pixel kernel remains a *private* function
in the defining module; there is no public `validated=true`
flag, unchecked indices/binding fast path or `@trusted` escape.

## 3a. Completed four-toolchain and kernel qualification

[GitHub Actions #38171946199](
https://github.com/alex-1974/imagery-d/actions/runs/38171946199)
completed **four of four jobs successfully**:

| Compiler | M3.2.6 debug/release and exact-arity forgery denial | M3.2.9 debug/release + DIP1000 | M3.2.11 private-execution denials | New verified-token forgery denial | Three-way full pixel oracle |
| --- | --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | PASS | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | PASS | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | PASS | PASS | PASS |

The previously stale M3.2.6 forged-marker probe now uses the
**correct current one-argument private constructor**, and fails for
access control on all four compilers; the newly added verified-token
probe likewise uses its constructor's exact three-argument signature
and is denied by visibility rules. Existing borrowed primary,
validity, metadata, nested ROI, and caller-mutable descriptor
negative gates remain PASS.

The optimized LDC 1.43.0 hosted evidence runner completed end to end:
**one** `researchExecuteCheckedPixels` executable definition with
call sites in original one-shot and prepared mapping; its
`audit_common_kernel.py` printed
`PASS: single common codegen kernel used by both mapped paths`.
The analyzer accepted **48 complete equal-checksum matched triples**
from one tiny cloud-runner process. It also saved
`m3212-unified-negatives.log`.

**Cloud timings remain a functional smoke test only.**
No XPS speedup or metadata preparation break-even for this new
source revision can be inferred from the four green jobs.

## 3b. Observed local XPS qualification (2026-10-11)

The operator supplied `prepared-20261011T203158Z.tar.gz`
(SHA-256 `f681b7133a9ab8e9139bf3e23650242cf2fa6dd8c799f463936886c27ccd45ca`),
measured against exact source commit
`1e0e0763ed7b4b75561aa4bd2aaac014e7a23d6e`.
Full methods, raw integrity, distributions and provenance are
retained in
[M3.2.12 — Dell XPS unified verified factory results](
m3-2-unified-sealed-factory-xps-results.md).

A separate parser reconciled **4,320/4,320 mapping rows** to
all five process logs and checked **1,440/1,440 complete
checksum-equal matched triples**, exactly balanced by call slot.
At **256 bands, 8×8**, conservative/verified/prepared median
map times were **779.2 / 695.8 / 612.5 ns** interleaved,
and **829.2 / 739.6 / 645.8 ns** planar+validity;
paired median conservative/prepared ratios
**1.2808×** and **1.2662×**, with prepared faster
**60/60** rounds for each layout. At 256 bands/64×64
the benefit becomes ~0.7–0.8% and does not justify a
general speed guarantee.

The new `unified_verified_binding_only` setup measures
**19–20 ns** across 3/17/64/256 bands, versus
M3.2.11's prior **114 ns** combined full-rescan/binding
stage at 256 bands. This is consistent with eliminating
the duplicate O(channels) scan but is **not a
same-run A/B regression measurement**. If two `.idup`
snapshots are needed purely to enable this path, a
~**43-small-ROI** reuse payback can be calculated under
the synthetic workload, but is **not release qualified**
owing to very short setup timing, hoisting, GC and
different ownership/consumer usage assumptions.

LDC 1.41 local debug/release positives and the M3.2.6,
M3.2.11 and M3.2.12 intended privacy/DIP1000 negative
contracts PASS. The optimized disassembly shows **one
shared private noninline pixel kernel** with callsites
from ordinary and prepared mapping.

**Test debt detected:** the *historical M3.2.9* forged
Prepared wrapper negative still invokes a superseded
multi-argument constructor. Its rejection occurs due to
signature mismatch rather than the required current
one-argument constructor privacy check. The current
M3.2.11/12 token privacy checks are precise. Update the
older test before production/API promotion.

The local raster checkout is not exactly tagged
`v0.2.0`; dynamic CPU governor/OS-default affinity
and nearly full swap are material reproducibility
caveats. This is audited **local-state research
evidence**, not a release performance guarantee.

## 4. Performance interpretation and remaining gates

The local XPS benchmark's previous label
`sealed_execution_validate_and_prepare` has been replaced by
`unified_verified_binding_only`. That is a **different operation
contract**: it measures the O(1) three-channel binding stage
when a verified immutable image already exists. It does not
include the initial O(channelCount) verification or any
explicit `.idup` snapshots, which retain their own setup rows.

The same XPS three-way runner continues to time conservative,
verified image/one-shot and Prepared ROI+pixel mapping against
equal output checksums, plus a source-independent exact pixel
oracle with planar/interleaved and independent validity.

- Hosted DMD 2.111 / 2.113 and LDC 1.41 / 1.43 debug/release
  are **correctness gates, not speed evidence**.
- The LDC optimized runner must show **one private, noninline
  `researchExecuteCheckedPixels` symbol** called from both
  ordinary and Prepared mapping after their respective checks.
- Exact-source optimized Dell XPS timing is now recorded
  in section 3b, but is **local-state research only**:
  the existing host `raster-d` checkout is off
  `v0.2.0`, swap pressure, frequency, affinity and
  preparation hoisting remain unresolved for release admission.
- To declare a release reuse threshold, improve the very
  short setup timing against D optimizer hoisting, quantify
  GC snapshot costs and choose representative consumer ROI reuse.

### Local XPS reproduction

From `libs/imagery-d`:

```bash
git fetch origin
git switch research/m3-2-unified-sealed-factory
git pull --ff-only origin research/m3-2-unified-sealed-factory

COMPILER=ldc2 REPEATS=5 ROUNDS=12 ITERATIONS=24 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_prepared_xps.sh
```

The runner now logs the new
`m3212-unified-negatives.log` alongside the existing M3.2.6,
M3.2.9 and M3.2.11 safety logs and hashes the timed binary.
It does not edit any sibling workspace repository.

## 5. Admission boundary

This is a research-only module organization, not a frozen public
imagery API. Do not merge the research chain wholesale into
`develop`. Preserve active stacked PRs and all older XPS,
safety, numerical and compilation evidence. Final production
admission still needs independent consumer requirements, broader
numerical/aliasing tests, production source/package boundary
review and pinned-dependency/performance qualification.
