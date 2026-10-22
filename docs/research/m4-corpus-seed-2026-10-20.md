# M4 — Reproducible imagery corpus, seed 1

Status: M4 IN PROGRESS, only fixture infrastructure. Issue #103.
No changes to public imagery-d D modules or historical research branches.

## Source and record contract

tests/corpus/m4-v1.json is a versioned internal manifest with 7 fixtures:
interleaved u8 RGB ROI, full RGB scene and two adjacent tiles, a one-plane
edit-selection mask (weights 0, 128 and 255), two-channel u16 and f32 cases.
Each entry records generator revision, synthetic provenance, OFFLINE retrieval,
dimensions, global pixel origin, channel count, sample format, byte length
and SHA-256. Synthetic values are not real photograph/satellite evidence.

All raw data are row-major, interleaved, and have no header/padding.
Exact integer pixel formulas at global (x,y), channel c:
- u8: (29*x + 31*y + 17*c + 7) mod 256
- u16le: (257*x + 4099*y + 1009*c + 11) mod 65536
- f32le: ((7*x + 11*y + 3*c) mod 128) / 128; finite exact binary32
- m4-mask-v1: single u8 plane, [0,128,255][(x+2*y) mod 3]

The two independent 4x4 RGB tiles are concatenated ROW-WISE and compared
byte-for-byte against the 8x4 scene. This proves fixture seam continuity,
NOT image mosaicking, blending or registration capability.

## Commands (Python standard library only)

Verify fixture bytes and recorded digests, no writes and no network:

    python3 tools/verify-m4-corpus.py
    python3 -m unittest discover -s tests/corpus -v

Optionally materialize 7 ignored raw files locally:

    python3 tools/verify-m4-corpus.py --materialize data/m4

Default verification makes no files. Generated raw files and external scenes
stay outside version control (data/ is ignored). A fixture is limited to
16 MiB. A failed hash, malformed ID or mismatched seam geometry makes the
validation fail. Manifest schema_version=1 is internal, NOT a frozen public
API. Files explicitly record little-endian u16/IEEE binary32, so no host
endian inference or accidental codec claims are needed.

## Deferred M4 scope

This seed has no URL sources, downloads, real-image licensing/provenance,
mosaics or cache/storage service. Those need explicitly checked sources,
permissions and optional offline retrieval before introduction. Never
silently label generated images as authentic imagery.

The Levels consumer connection is recorded below. ADR 0007 subsequently
admitted a scoped RGB8 histogram (PR #108), independently of historical
research PR #77. The next corpus step verifies that admitted operator;
fixture tooling itself does not admit public APIs.


## First actual operator consumer — 2026-10-20 (follow-up to seed)

Issue #105 adds a tiny Python runner to the **existing M3 P6 Levels
consumer gate**, without another D build, benchmark or public module.
After manifest SHA verification, the runner wraps four M4 RGB raw
fixtures in valid P6 headers and calls the real DUB-compiled Levels
executable (gamma 2). It checks every output byte against an
independently computed Python sqrt+round oracle. It then processes
the 4x4 left/right tiles separately and verifies their row-wise
concatenated results exactly equal the 8x4 whole-scene result.
This qualifies the **pixelwise Levels operation on this sample corpus**,
not general halo-dependent filters, resampling or mosaicking.
No image files are tracked or silently downloaded.


## RGB histogram file consumer — 2026-10-22

Issue #109 connects the admitted ADR 0007 API to the same manifest-hashed
RGB P6 fixtures using the existing test consumer executable. Its internal
report mode is not a released CLI or imagery-d serialization/codec API:

```sh
dub build --root=tests/ppm_consumer --compiler=ldc2 --build=release
python3 tests/corpus/verify_m4_histogram.py \
  tests/ppm_consumer/m3-levels-production-ppm /tmp

# Inspect a separately supplied P6 RGB8 image; ROI is source-relative:
tests/ppm_consumer/m3-levels-production-ppm \
  --histogram input.ppm 0 0 128 64 optional-mask.raw
```

The optional headerless mask is one u8 byte per pixel on the FULL source
grid, exactly width * height bytes. Zero excludes and every nonzero byte
includes once. This deliberately interprets the existing 0/128/255 fixture
as a binary inclusion mask, rather than Levels' fractional editing strength.
Only a successful complete record is printed as JSON: three 256-bin
histograms, included/excluded pixel counts, minima, maxima and means.
Failure exits without a JSON result. Input files are never overwritten.

The Python runner verifies the manifest and SHA-256 digests before any
consumer call. It computes exact bins/extrema/counts directly from decoded
input bytes and means from independent rational sums. Bins, counts and
extrema must match exactly; finite double means use absolute tolerance
1e-12 (small byte-domain fixtures and JSON double serialization). The
14 positive cases cover whole images, non-origin ROIs, crossing a tile
boundary, independently masked tiles, zero/all/single inclusion, and a
CRLF P6 header whose first pixel contains whitespace bytes. Whole-scene
counts and bins must equal the sum of the adjacent nonoverlapping tiles.
The 11 invalid requests cover malformed arguments, bounds/empty ROI,
wrong mask sizes and malformed/truncated P6 inputs, with no JSON output.

Existing DMD/LDC Debug+Release jobs build the consumer once and run both
Levels and histogram corpus checks; the independent offline fixture gate
remains in place. This is synthetic fixture evidence, not external-image
adoption, real-photo provenance, performance qualification or a release.

## RGB percentile contrast P6 consumer — 2026-10-22

The existing P6 executable also supports the internal test mode
`--stretch INPUT.ppm NEW_OUTPUT.ppm LOWER UPPER`. It computes a full-image
RGB histogram, builds a per-channel percentile stretch LUT, and applies that
map to all stored RGB bytes before writing a new P6 image. The output path
must be new. No mask is accepted in this file mode; the library LUT itself
can be built from a masked histogram, but mask selection only estimates its
thresholds and does not silently define which pixels receive the map.

`verify_m4_stretch.py` verifies manifest hashes first, then compares the
actual P6 output bytes from four RGB fixtures to an independent Python
nearest-rank and rational interpolation oracle. It also checks a constant
channel, original file preservation and rejected invalid percentile requests
without partial output. The DMD/LDC Debug+Release matrix reuses the already
built P6 consumer. This is a synthetic byte-level consumer, not an assertion
about colour-managed contrast, real imagery or a published CLI.

## RGB histogram-equalization P6 consumer — 2026-10-22

The internal `--equalize INPUT.ppm NEW_OUTPUT.ppm` mode computes a full-image
RGB histogram, obtains three independent byte lookup tables, and writes a
new P6 image. `verify_m4_equalize.py` first verifies the manifest and SHA
digests, then compares four RGB output images byte-for-byte with an
independent Python `Fraction` CDF oracle. A flat R channel, preserved input,
refusal to overwrite an output and malformed invocation are also checked.
The DMD/LDC Debug+Release matrix reuses the existing P6 build. This mode
does not claim colour-managed output or define a released CLI.
