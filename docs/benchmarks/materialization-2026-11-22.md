# Native-plane and RGB materialization — 2026-11-22

Scope: #174/#175 hardening and a concrete #145 metadata handoff fixture in
draft PR #205. Upstream decoder repair is isolated in
[imageio-d PR #26](https://github.com/alex-1974/imageio-d/pull/26), commit
`ea65f51f11f415491ee5ebe78f3594b1cdc3b9fd`. Neither repository publishes a new
version or rewrites a release tag as part of these changes.

## Correctness and scope

An independently generated 19-by-13 JPEG 4:2:0/4:2:2 pair is decoded through
imageio's public full-plane and odd-origin region entry points. Native copying
preserves component dimensions, roles, sampling factors, storage origins, center
and crop offsets, including unknown source facts. Synchronous inspection copies
no samples. RGB conversion rejects unknown/incompatible geometry and color;
positive tests separately declare the fixture provider's interpretation, never
pretending the JPEG codec supplied missing phase/range/transfer/primaries.

The ordinary DUB consumer and independent rational/YCbCr Python reference cover
**193 cases / 20,991 pixels**: four matrix/range policies, nearest/bilinear,
float32/float64/u8, padded rows, independent axis phases, nonzero origins around
2^63, shifted equal-size planes, explicit reordered roles and four real decoder
regions. Whole/ROI requests using the necessary source samples are exact, as
are array/direct-owned representations of the same sample type.

| Metric | Observed maximum | Gate |
|---|---:|---:|
| Float64 channel absolute error | 4.441e-16 | 3e-15 |
| Float32 channel absolute error | 5.957e-8 | 2e-7 |
| Byte discrepancy | 0 | Exact, except adjacent-byte choice only at a true half boundary |

The float64 gate covers alternate evaluation/IEEE rounding (6.75 times the
observed maximum); float32 allows representation rounding (3.36 times observed).
The one-byte exception requires an independent unrounded reference within
1e-10 code units of an actual half quantizer, rather than allowing ordinary
one-byte numerical errors. It is unused in this measured corpus.

34 external structured-error/rollback probes cover shape/count/role errors,
geometry status/denominators/factors/phase limits, conflicting and missing color
facts, matrix/range mismatch, unsupported transfer/primaries/bit depth and signed
source metadata. Exact output-budget failure preserves prior owned samples and
retained aliases. Ordinary unittests additionally protect empty `.init`, raw
copy overflow/layout/budget behavior and the originally failing fractional RGB
case. In the old adapter, bilinear interpolation was prematurely rounded to
bytes and used an unrelated half-pixel convention; the new reference regression
failed before the correction.

Local qualification: six supported compilers pass default/no-io (24/23 unittest
modules), DMD 2.111 Debug and LDC 1.43 Release consumers/references pass, and
default DIP1000 probes compile the named `@safe` owned/inspection calls while
rejecting callback retention. Existing nine negative contracts remain intact.
Native aggregate-slice retention is explicitly a semantic caller rule: the
compiler does not reject every nested data-slice escape. Rendered DDOX includes
the public owned type, status/result types, fields and executable examples.

## Real geospatial handoff and decoder dependency

GDAL creates a single-band GeoTIFF with EPSG:32633, PixelIsArea, a north-up 2 m
grid and declared NoData=0. The consumer reads ROI (3,1,9,7), materializes exactly
63 output bytes, then poisons/releases decoder input. Retained samples remain
correct. GDAL independently confirms source/ROI transforms, extent, first sample
center, GSD, band/unit identity, absent alpha and separately derived validity.
The fixture carries explicit source/revision/grid identities and policy names.
CRS interpretation stays in the consumer, not imagery-d. This is a contract
fixture, not deployed multi-tool Dunia acceptance or human-reviewed ground truth.

Released imageio-d 0.1.1 rejects the ordinary three-band RGB variant before
reading its component BitsPerSample array. After resolving that upstream,
end-to-end validation also revealed the decoder's incorrect interleaved sample
stride. The isolated fix repairs inspection/planning and compact stride metadata.
The same consumer/oracle then passes a 189-byte RGB owned raster and its full
geospatial/NoData handoff on both DMD and LDC.

The upstream regression corpus contains 24 permanent header/byte-order/depth/
component combinations and malformed cases. GDAL independently produces/reads
48 classic/BigTIFF strip/tile files: 192 full/ROI cases / 49,824 exact samples.
No TIFF parser or refcount implementation is copied into imagery-d. A temporary
direct dependency override qualifies the candidate without altering global DUB
registrations or the ordinary released-package gate. Until a fixed version is
integrated/released, the default baseline deliberately records the RGB failure.

Local fixture hashes (Python 3.14.8, numpy 2.5.5, Pillow 13.0.0,
GDAL 3.13.3 "Iowa City", released 2026-08-13):

| Fixture | SHA-256 |
|---|---|
| JPEG 420 | `96a5808dd60499b43e620e68e94fdecdb930bc977426d8ada88c36fca8b46240` |
| JPEG 422 | `85e308dafde5c07b70ad17044db04c5ffb0a01cbab75fb70f64d83de6dddcb18` |
| Scalar GeoTIFF | `2f94e4dff4e32b7ac6d9f81ccdecc857cf1f2c309d0b2de50a68f3dabb9963d4` |
| RGB GeoTIFF | `e32a1f99646af119d4ff27ae2f005745135b69df11e5a0703a1f431e2d644fac` |

The generator and source equations are retained; codec/tool versions can change
encoded bytes, so these hashes are receipts rather than a cross-version gate.

## Native materialization cost

Host: Linux x86_64, Intel i7-9750H, LDC 1.43.0 DUB release, CPU 0. Source u8
YCbCr planes are prepared outside timing; each axis has full-resolution luma and
half-resolution chroma with declared independent fractional phases. BT.601 video
policy produces encoded float or clipped bytes. No actual codec/file/GDAL work
is included in these operation timings.

Each case warms once, then measures five complete owned calls, paired in each
cycle with the equivalent array operation. Owned always precedes array; ordering
is not randomized. Checksums run after timing. Direct output allocation,
preflight, sample interpolation, color conversion, writes, metadata publication
and old-owner replacement are included. Safe checks remain enabled. No other
agent builds or CPU-heavy tests run during this pinned series. Background desktop/
VM load, SMT sibling, thermal/frequency state are not controlled; spreads are in
the [raw receipt](materialization-2026-11-22.txt).

| Size | Geometry | Sample | Owned ns/pixel | Array ns/pixel | Owned GC bytes | Array GC bytes |
|---|---|---|---:|---:|---:|---:|
| 256² | Nearest | float | 93.852 | 98.378 | 0 | 790,528 |
| 256² | Nearest | u8 | 103.294 | 104.932 | 0 | 200,704 |
| 256² | Bilinear | float | 107.076 | 110.127 | 0 | 790,528 |
| 256² | Bilinear | u8 | 121.744 | 122.346 | 0 | 200,704 |
| 1024² | Nearest | float | 93.896 | 90.224 | 0 | 12,587,008 |
| 1024² | Nearest | u8 | 95.399 | 93.059 | 0 | 3,149,824 |
| 1024² | Bilinear | float | 105.854 | 105.407 | 0 | 12,587,008 |
| 1024² | Bilinear | u8 | 115.364 | 110.689 | 0 | 3,149,824 |

Direct ownership removes the measured GC payload; it is **not a universal speedup**.
It is about 4.1–4.2% slower than the array form in two 1024² cases, with overlapping
spreads and additional ownership/metadata behavior. Every direct call still
allocates C/raster-owned output (3N or 12N bytes here); zero observed GC is not
zero allocation. The public raster importer does not promise `@nogc`/`nothrow`,
so the materializer deliberately does not advertise those attributes. An explicit
DMD/LDC compile challenge confirmed that boundary. Do not cast away it or infer
an attribute contract from a common-case timing receipt.

This is separate from #144's full mosaic/display 60 fps gate and is not a
real-decoder/display latency claim. Production dependency release, broad
application/scene acceptance, progressive tool delivery and #186 region semantics
remain open.

## Reproduction

```
dub build --root=tests/materialization --compiler=dmd-2.111.0 --build=debug
python tools/verify-materialization.py tests/materialization/materialization-consumer
dub build --root=tests/materialization --compiler=ldc-1.43.0 --build=release
python tools/verify-materialization.py tests/materialization/materialization-consumer
taskset -c 0 tests/materialization/materialization-consumer --bench
python tools/verify-imageio-candidate.py /path/to/imageio-checkout --compiler=ldc-1.43.0
```

The Python tests require the pinned numpy/Pillow versions in
`tests/materialization/requirements.txt` and the GDAL CLI tools. GDAL is test-only,
not a library/runtime dependency. The release-readiness workflow runs the
released-package consumer; the explicit candidate command exercises the fixed
upstream checkout. ADR 0018 and the materialization guide define the exact
metadata, coordinate, clipping, phase-domain and failure contracts.
