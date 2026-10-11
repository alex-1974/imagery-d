# M3.2.12 — One immutable verification factory for sealed semantic mapping

**Status:** Implementation in stacked research PR
[#47](https://github.com/alex-1974/imagery-d/pull/47).
**Compiler, codegen and hardware gates must all be checked before any
positive qualification claim.** No public API is admitted.

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
- Optimized Dell XPS performance must be measured on the
  new exact source revision before any speedup/amortization
  claim. The existing host `raster-d` checkout off
  `v0.2.0`, swap pressure, frequency, affinity and
  preparation hoisting remain explicit potential confounders.
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
