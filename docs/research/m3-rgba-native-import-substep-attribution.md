# M3 RGBA — public raster-d import substep attribution (Issue #74)

**Status:** Research implementation and pinned-source hypotheses.
**Native XPS qualification:** **PENDING.** Do not report the following
type/call-site hypotheses as measured allocations or as a production budget.
**Boundary:** all new code is independent `imagery-d` research-consumer code.
No `raster-d` or `color-d` source has been modified.

## Baseline

Two already verified 48-process XPS control captures (96 independent
processes total) compared `markers`, `raw`, `import`, `full`.
Relative to `raw`, each `import` generation had 10 additional
interposed malloc-family requests (592 requested bytes), six producer-
temporary requests (392 bytes) and four last-owner-retained requests
(200 bytes). Neither requested bytes nor reported RSS/GC counters are
a complete physical allocation budget.

See [the checked XPS controls and replication]
(m3-rgba-native-allocation-controls-xps-2026-10-15.md).

## Pinned upstream source audit, 2026-10-15

Read-only source SHA:

- `raster-d v0.2.0`:
  `2f2415851e45001df92ce56dad409f680684ba8d`
- `color-d v0.2.0`:
  `3359f08f4e83941ac1a8451cadefb146b5736019`

The precise public operation chain is:

1. `tryAdoptMallocResource` in
   [`source/raster/owned_resource.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/owned_resource.d).
   Success populates the move-only `OwnedByteResource` from the raw
   pointer/size/release callback; the audited body does not call malloc.
2. `tryImportOwnedRaster!T` in
   [`source/raster/import_owned.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/import_owned.d)
   delegates to the single-resource importer.
3. [`source/raster/import_single_resource.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/import_single_resource.d)
   mallocs a temporary `PlaneDescriptor` array, converts and validates
   the layouts, transfers the physical resource, then frees that
   temporary descriptor array when import returns.
4. [`source/raster/construction.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/construction.d)
   mallocs and copies stable `ResourceEntry` and `PlaneDescriptor`
   metadata tables.
5. [`source/raster/backing.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/backing.d)
   mallocs a `RasterBackingControl`, registers the backing with
   `GC.addRange`, and frees the control and retained tables on final
   owner release after unregistering the GC scan range.

For the pinned Linux x86-64 / 64-bit D object layouts, source fields
imply the following **layout hypotheses**. They are not measured
allocator usable sizes:

| Source object or step | Calculated size | Expected request |
|---|---:|---|
| One `PlaneDescriptor`: pointer + 2 signed strides | 24 B | 24 B |
| One `ResourceEntry`: 4 pointers/sizes plus access + padding | 40 B | 40 B |
| `RasterBacking`: two slices, two pointers, 4-size_t region | 80 B | Embedded |
| `RasterBackingControl`: backing + size_t refcount | 88 B | 88 B |
| Four-plane descriptor copy | 4 × 24 B | 96 B |
| `GC.addRange`-associated unknown request | Not established | **48 B candidate only** |

The source-backed 24/40/88/96 shapes align with the prior anonymous
malloc-size histogram, but identity of a particular malloc event must
be demonstrated by its enclosing operation and lifetime. The observed
48-byte blocks may be side effects of `GC.addRange` / druntime but this
**is not yet attributable**; no unverified allocator-stack inference is
authorized.

### Falsifiable predicted lifetime signature

The next trace isolates two real imports per generation: one
four-plane `ubyte` scratch and one single-plane packed `SRgba8`.

| API step | Predicted additional requests | When corresponding pointers should free |
|---|---|---|
| Adopt scratch pointer | 0 | Adoption transfers obligation only |
| Import scratch (4 planes) | 96 temporary + 40 table + 96 table + 88 owner + 48 unknown = **368 B** | Temporary 96 B at end of import, remaining **272 B** at final scratch lease close |
| Scratch borrow / retain | 0 | No new physical backing |
| Adopt packed pointer | 0 | Adoption transfers obligation only |
| Import packed (1 plane) | 24 temporary + 40 table + 24 table + 88 owner + 48 unknown = **224 B** | Temporary 24 B at end of import, remaining **200 B** at final packed lease close |
| First packed-owner close | 0 new bytes | Independently retained second lease must stay valid |
| Final packed-owner close | 0 new bytes | **200 B** of predicted metadata freed |

Thus the candidate prediction is **368 + 224 = 592 B**
of import-associated requests; producer-temporary
`96 + 272 + 24 = 392 B`, retained packed
`40 + 24 + 88 + 48 = 200 B`. This exact arithmetic
reconstructs the old histogram but **does not itself prove
the individual underlying type origins**.

The decisive observations will be a stage-isolated trace in which
the 368 B requests occur inside the scratch import call and the
224 B requests inside packed import, with the predicted free stages.
If a 48 B request originates elsewhere, do not relabel it to force
the expected pattern.

## New independent research probes

- `smoke/source/native_import_substeps.d`:
  `--native-import-substeps --case=raw|adopt|import --side=16|256`.
  The mode shares instrument/accounting baseline, but deliberately
  omits compositor, source fixtures and cache policy; this is an
  isolated imported-resource control, **not** a direct replacement
  for the earlier full-path 48-process study.
- Reuses the existing unchanged `alloc_events/m3_alloc_events.c`
  and opt-in `native-allocation-events` DUB config.
- `tools/research/summarize_m3_rgba_native_import_substeps.py`
  checks the 13 event stages, both tagged physical buffers,
  pointer identity, duplicate allocations, unexpected/tagged frees,
  and invalid/dangling intents. It writes per-stage anonymous
  event-request bytes, counts, and still-live requested bytes,
  without naming private D types.
- `tools/research/run_m3_rgba_native_import_substeps_xps.sh`:
  exact LDC 1.43 and pinned `raster-d/color-d v0.2.0`,
  immutable `git archive HEAD` snapshot, 3 controls × 2 ROIs
  × 3 independent processes = **18 proposed native XPS runs**
  (smoke: 6). Keeps raw event streams and matched per-stage
  difference CSV, environment/build logs, and SHA-256 manifest.
- Independent DMD/LDC compile matrix and optimized LDC native
  trace CI are required gates, not substitutes for a native XPS
  archive and independent checksum replay.

Stage contract:

| Stage | Target |
|---:|---|
| 1 | Common accounting baseline |
| 2 | Explicit tagged scratch malloc |
| 3 | Public scratch adoption (where enabled) |
| 4 | Public four-plane scratch import (where enabled) |
| 5 | Scratch view/retain |
| 6 | Explicit tagged packed malloc |
| 7 | Public packed adoption (where enabled) |
| 8 | Public one-plane packed import (where enabled) |
| 9 | Packed view/retain |
| 10 | Final scratch retirement |
| 11 | Release first packed lease while copy survives |
| 12 | Final packed lease retirement |
| 13 | Terminal no-owner assertions |

## Admission boundary

The existing source-over correctness oracle and multigeneration
lifetime work remain intact. No public imagery API, new raster
refcount semantics, thread safety, direct mmap coverage, allocator
usable/resident size estimate, all-in cache capacity formula or
release/merge is admitted by this step.

**Disposition before new measurements:**
ADAPT targeted attribution research, DEFER all-in-budget and
production API. Keep Issue #74 and stacked Draft PR #73 open.
