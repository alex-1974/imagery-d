# M3.2.8 — Real image-domain ROI mapping versus metadata preparation

**Status:** Experimental research. No production `ImageView` API or
metadata allocator admitted. Builds on [M3.2.7 XPS ROI evidence](
../../docs/research/m3-2-xps-roi-observed-results.md) and preserves
all previous M1/M3.2 experiments.

## Research question

M3.2.7 established a strong **ROI construction-only** improvement for
immutable validated channel identities (1,024 channels: 605.10 ns
conservative versus 21.22 ns validated on the measured local XPS).
An actual consumer also reads stored raster pixels, interprets
physical scale/offset, handles validity and writes a destination.
Furthermore, if input metadata is mutable, it must first be copied
before the immutable-only fast capability can be created.

This experiment measures those missing costs **separately**, without
assuming that the large ROI-only speedup survives image work.

## Matched consumer operations

Both variants use the *same* source and destination representation,
the existing `raster-d` resource leases and the same M3.2.2
`mapComponentsInto` image-domain operation:

1. **`revalidated_image`**: M3.2.3 `BorrowedSemanticImage.tryRoi`,
   followed by the existing three-component physical-value mapping.
2. **`verified_immutable_image`**: M3.2.6
   `ValidatedImmutableImage.tryRoi`, followed by **the same** mapping.

Each operation explicitly binds the final three logical channels,
applies `physical = stored*0.5-4`, propagates the existing test-only
invalid-mask-to-zero rule, and writes a separate 3-plane float destination.
Independent exhaustive output oracles run over multiple ROI positions
**before timing**. Each timed pair uses identical source windows
and checks an observable output sample and matched checksums.

The source is a resident **synthetic** image, not a decoded physical
image file. This is consumer-level pixel work but not a decoder/end-to-end
pipeline or production application benchmark. The M3.2.2 mapping
implementation still validates channel IDs on every call; hence
there is no presumed O(1) overall image-mapping path.

## Corpus

- Channel counts 3, 17, 64, 256.
- Common source grid 96×96, output regions 8×8, 32×32, 64×64.
- Planar with a separate `ubyte` validity mask and
  interleaved without mask.
- Distinct channel identity and stored values; nontrivial per-pixel
  validity, integer-valued synthetic input and exactly representable
  `0.5` calibration. **This is not a general radiometric accuracy
  corpus**.
- Balanced alternating order, warmup, repeated measurements.
- Same source, immutable metadata, destination sizes and mapping
  arithmetic in both timed paths.

`mapConservative` and `mapVerified` are explicitly noninline
wrappers for later codegen review. Each returns an independent success
flag; failed mapping cannot be disguised as a floating-point `NaN`
sentinel. D initializes unspecified floating-point values to `NaN`,
so the checksum accumulator is deliberately initialized to `0.0`.

## Preparation model and break-even caveats

For each channel count, record elapsed nanoseconds per call for:

- `caller_borrow_validate`: create ordinary M1.5 and M3.2.3
  views over retained caller mutable descriptors; **zero**
  implicit imagery metadata snapshot copies.
- `already_immutable_validate`: create the immutable
  M3.2.6 capability from a caller's already-immutable descriptor
  arrays; no metadata allocations in the factory.
- `snapshot_and_validate`: explicitly `.idup` both input
  descriptor arrays **once** and construct the immutable capability.

The `.idup` case uses two GC-backed descriptor-array copies and does
not deep-copy referenced string contents. These preparation timings
are outside the ROI/pixel loop. Allocation and GC timings are
affected by collection state. The operation does not include file
decoding, colour-space transforms, parallelism or cache management.

A possible **amortization estimate** may later compare
`snapshot_and_validate - caller_borrow_validate` against measured
mapping savings per ROI. It is only meaningful when both routes
provide equivalent required caller semantics and the time difference
is positive and statistically stable. Otherwise no meaningful
break-even count exists. Prefer evidence over extrapolating the
M3.2.7 ROI-only ratio into an image-pipeline claim.

## XPS procedure (read-only in sibling repositories)

From `libs/imagery-d` after fetching the research branch:

```bash
git fetch origin
git switch research/m3-2-consumer-amortization
git pull --ff-only origin research/m3-2-consumer-amortization

COMPILER=ldc2 REPEATS=5 ROUNDS=9 ITERATIONS=12 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_consumer_xps.sh
```

The runner stores version, CPU and build provenance, DMD/LDC-style
positive and negative compiler preflight logs, SHA-256 of the timed
binary, per-process raw mapping/setup rows, medians and MAD,
symbols and compressed disassembly under
`experiments/m3_2_validated_roi/evidence/local/consumer-*`.
These artifacts are gitignored by the existing research evidence
rule. The script never runs `git clean`, checkout or reset in
`raster-d` or any other workspace repository.

If the sibling `raster-d` commit is not the exact `v0.2.0` tag,
the result is explicitly labeled as local-state research and
not a pinned release reference, consistent with M3.2.7 evidence.

## Decision boundary

This experiment is designed to answer *whether* the validated
immutable ROI is useful for an actual mapping consumer and at what
metadata reuse count. It does **not** remove the mapping kernel's
per-call semantic validation, invent a new allocator, admit a final
public type, or change accepted ADR 0002/0003. Keep codegen,
DIP1000 and numerical claims tied to real compiler/toolchain evidence.

Tracking [Issue #38](https://github.com/alex-1974/imagery-d/issues/38)
and [PR #39](https://github.com/alex-1974/imagery-d/pull/39).
