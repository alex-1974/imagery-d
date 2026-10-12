# M3.2.18 — Long-lived semantic metadata source and order-sensitive ROI evidence

**Status:** research-only source adapter and evidence harness, not a public
`ImageLease`, caching API, generic allocator or production speedup.
[Issue #58](https://github.com/alex-1974/imagery-d/issues/58),
[stacked draft PR #59](https://github.com/alex-1974/imagery-d/pull/59)
above [M3.2.17 PR #57](https://github.com/alex-1974/imagery-d/pull/57).

## Inherited contracts and motivation

The [M1.5 image view research](m1-image-view-contract.md) already demands
immutable semantic metadata shared by child ROIs without cloning. The
M3.2.12 `ValidatedImmutableImage` and `PreparedSemanticMap` implement
DIP1000-tracked, private verified execution over genuinely immutable
channel descriptors with `@safe @nogc` ROI mapping.

[M3.2.17 independent XPS evidence](m3-2-metadata-owner-xps-results.md)
proved that two immutable metadata snapshots **once** across 32 packets
remove 96.875% of repeated snapshot volume: 17,744 GC bytes once
versus 17,744 per packet. No policy or GC-disabling trick is needed.
However the previous aggregate first-lane checksum repeats every four
ROI origins: arbitrary permutations in a four-origin cycle can preserve
that sum. A separate full three-channel *last-ROI* oracle remained,
but did not independently check every intermediate ROI.

The next question is **semantic publication at a source boundary**, not
a new general-purpose storage facility.

## Narrow source model

`ResearchLongLivedMetadataSource`, in
`experiments/m3_2_validated_roi/source/m3_2_metadata_source/contract.d`:

- `fromImmutable(immutable(ChannelDescriptor)[],
  immutable(IntrinsicChannel)[])`: retain existing genuine immutable
  GC-backed slices, without another copy.
- `snapshot(scope const(ChannelDescriptor)[],
  scope const(IntrinsicChannel)[])`: take **two independent immutable
  `.idup` copies once**. `const` backing might still have mutable
  aliases, so no cast-based freeze.
- `tryMapOrderedInto`: borrow the caller's source and optional validity
  raster, validate against the immutable source once **per invocation**,
  prepare one checked binding and execute a series of actual 3-channel
  physical ROI mappings. Results write into caller-provided output
  and two caller-owned arrays of length `roiCount × 3`, containing
  the first and last pixel of each selected output component for
  **every ROI in its original order**. The method is `@safe @nogc`
  and returns checked error status without retaining pixel pointers.
- The source adapter does **not** own raster resources, introduce
  `RasterLease` life-cycle duplication, return a floating Prepared token,
  or promise a cached Prepared value *across* calls. Re-validation per
  call is a deliberate correctness limitation, not an optimization.

A genuinely new mutable source state is published only by constructing
a **new** immutable metadata source. Existing source instances remain
unchanged and can serve an old-generation request. Each source holds
immutable GC-backed references and needs no separate GC suppression,
pool, ref counting or unsafe `@trusted` cast.

## Real pixel / alias experiment

For both modes (`immutable`, `snapshot`):

1. Construct a 256-plane planar source, actual validity mask and
   reusable three-plane ROI destination. Start with 256 metadata entries
   at scale `0.625`, offset `-6`, source label `NIR`.
2. Create the old immutable source once, then **modify every original
   mutable IntrinsicChannel element** to scale `0.6875`,
   offset `-7`, label `REFRESHED`. A new source explicitly
   captures this later generation, while the old immutable source
   must retain its original semantics (including label).
3. For each original/refreshed source, process independently
   configurable 8×8/32×32 windows, 4/16 ROI calls and 1–8192
   numbered packets. Output destinations, ROI requests and
   observation arrays are preallocated.
4. Each ROI emits a **separate ordered** record:
   `phase, packet, roi, x, y, first[0..2], last[0..2]`,
   plus the source policy and configuration. A separate packet record
   stores elapsed mapping+validation time and GC-allocation delta.
5. D computes the expected physical value independently for *every
   observed component and two pixels per ROI* and retains the
   existing **full three-component final-ROI image oracle**.
   An external Python analyzer reconstructs every origin, component,
   calibration, validity and sample *independently from logs*.
   No order-insensitive sum or self-referential `checksum==expected`.
6. The analyzer rejects missing/duplicated/reordered source-process
   and ROI records, wrong phase or packet, mismatched coordinates,
   forged physical sample values, nonzero per-packet GC allocation,
   unobserved refresh, invalid headers and malformed timing.
   Positive/negative synthetic CLI-to-CSV/JSON fixtures are required.

The first/last corner fingerprints do not cover **every pixel of each
intermediate ROI**; intermediate interior corruptions still require
stronger per-ROI full-pixel or rolling full-image oracles if
production correctness later depends on them. This improvement fixes
the known ordering blindness, not every possible pixel fault.

## Ownership and qualification limits

- `immutable(T)[]` and `const(T)[]` are distinct. No zero-copy
  mutable→immutable transformation is introduced or admitted.
- The source retains **metadata only**; external `RasterLease!float`
  and `RasterLease!ubyte` owners must outlive the borrowed mapping
  session. The existing private checked mapping and DIP1000 negative
  escape tests remain mandatory.
- Immutable initial construction and refresh are **outside timed
  packet calls**. No benchmark can claim the lifetime setup free.
- This source method deliberately performs verification and Prepared
  binding once **per packet**, unlike M3.2.17's reuse of a Prepared
  value across packet mapping. It is **not an equivalent A/B
  performance winner**; no regression or break-even interpretation
  may be made from absolute packet times without a fair same-work
  comparison. The only proposed M3.2.18 performance property is
  **zero new GC metadata allocation in the packet method**.
- Hosted CI smoke validates semantics under DMD 2.111/2.113 and
  LDC 1.41/1.43; the XPS evidence script records commit IDs,
  compiler, local `raster-d` dependency state, binary hash,
  disassembly, system memory/swap and process logs. A full XPS
  qualification is required before local latency/tail claims.
- No sibling repository changes or automatic merger of the
  active stacked research history.

## XPS reproducibility (once four-compiler gates pass)

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short --branch
git fetch origin
git switch research/m3-2-18-metadata-source-ordered-roi
git pull --ff-only origin research/m3-2-18-metadata-source-ordered-roi

COMPILER=ldc2 REPEATS=5 PACKETS=32 SIDES=8,32 REUSES=4,16 \
  bash experiments/m3_2_validated_roi/tools/qualify_metadata_source_xps.sh
```

Default: 5 process repetitions × 2 distinct metadata-owner modes ×
2 ROI sides × 2 reuse counts = **40 processes**, each with
**64 packet observations** (32 original + 32 refreshed), total
**2,560 packet observations** and **25,600 ordered ROI records**
(5×2×2×32×2 phases×(4+16)).

`qualify_metadata_source_xps.sh` and
`analyze_metadata_source.py` emit raw ordered ROI/packet/process
CSVs and a separately checked JSON summary. Hosted smoke is
**not** a reference-performance measurement.

## Admission decision

**Admit only if:** complete process/packet/ROI transcripts, all six
physical samples independently match each window, explicit refresh
does not mutate the old owner, no GC allocation within the checked
`@nogc` mapping call, existing scope/forgery tests and the
four-toolchain compiler matrix all pass.

**Do not promote by default:** public `ImageLease`, memory pools,
zero-copy mutable freeze, cross-packet Prepared caching, guaranteed
worst-case latency, new raster-d/containers-d APIs or a release
performance factor. Those need their own consumer and independent
research gates. Maintain M3.2.18 as stacked **draft research**.
