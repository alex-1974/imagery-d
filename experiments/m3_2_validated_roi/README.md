# M3.2.6 — Validated-once ROIs for immutable channel metadata

**Status:** research-only comparison; no new public API or production
admission.

## Why this experiment

M3.2.3's `BorrowedSemanticImage.tryRoi` obtains an M1.5 raster ROI
and then invokes `tryBorrowSemanticImage`, which compares all channel
semantic identities again. M3.2.5 established this **O(channel-count)
metadata revalidation** cost as a possible performance issue.

Simply skipping that scan for an arbitrary `const(IntrinsicChannel)[]`
would be unsound **semantically**: `const` prevents mutation through the
view but callers can mutate the original backing from another alias.
The earlier M3.2.5 experiment explicitly showed this behavior.

This experimental variant is restricted to **true D `immutable`**
identity and intrinsic metadata slices. The constructor validates those
identities once. Derived ROIs retain the same immutable metadata and
rely on M1.5 `ImageView.tryRoi` for coordinate, plane-count and validity
extent checks, without rewalking intrinsic IDs.

```text
raster-d RasterLease!float         immutable M1 / intrinsic descriptors
           |                                 |
           +----------> validate once <------+
                              |
                     ValidatedImmutableImage
                              |
                   tryRoi / nested tryRoi
                              |
                   same immutable identities
                   O(1) descriptor work
```

The raster view still borrows from the caller's `raster-d` lease and
cannot escape it. No new pixel owner, metadata allocator or mutable
capability is introduced.

## Scope and deliberate limits

- The **existing** conservative `BorrowedSemanticImage.tryRoi` stays
  unchanged for callers using merely `const` metadata.
- `tryMakeValidatedImmutableImage` requires
  `immutable(ChannelDescriptor)[]` and
  `immutable(IntrinsicChannel)[]`; it never silently converts
  `const` to `immutable`, allocates or snapshots metadata.
- Factory validates equal metadata counts, matching semantic IDs,
  raster planes and optional same-grid validity.
- The factory produces an inert `.init` result on failure.
- ROI shares immutable metadata, derives the physical region through
  **the existing M1.5 ImageView implementation**, and reports failed
  or out-of-bounds regions instead of silently clipping.
- The M3.2.2 `mapComponentsInto` operation currently **still
  revalidates channel IDs on every mapping invocation**. This experiment
  only improves ROI construction; do not claim end-to-end pixel-operation
  gains from ROI timing.
- Neither type is admitted as a public `imagery-d` API.

## Qualification matrix

- DMD 2.111.0 / 2.113.0 and LDC 1.41.0 / 1.43.0, debug and release.
- Synthetic 3, 4, 17, 64 and 256-channel images; planar with validity
  and interleaved without validity.
- Exact mapped pixel values for four uneven ROI partitions versus the
  original conservative `BorrowedSemanticImage`, checked against a
  separate arithmetic oracle; nested metadata pointer identity.
- Invalid ROI, `.init`, descriptor count / semantic ID, source-plane
  count and validity-grid mismatches.
- D `@safe` DIP1000 compile-negatives: escaping local primary,
  validity, immutable metadata, or nested ROI; plus one compile-negative
  showing a merely `const` descriptor cannot enter the immutable-only
  factory.
- Advisory controlled-shape ROI timings with channel counts 3/17/64/
  256/1024; offsets vary. Hosted-runner numbers are **not**
  XPS release qualification and can be affected by hoisting, timer
  granularity and shared-host contention.

## Run

```bash
bash experiments/m3_2_validated_roi/tools/run.sh
```

Single compiler plus optional advisory benchmarks:

```bash
COMPILERS=ldc2 RUN_BENCHMARK=1 \
    bash experiments/m3_2_validated_roi/tools/run.sh
```

Neither the shared workspace nor other repositories are modified.
This experiment is stacked on M3.2.5 research, and it preserves
previous failed or exploratory histories.

Tracking [Issue #34](https://github.com/alex-1974/imagery-d/issues/34).
