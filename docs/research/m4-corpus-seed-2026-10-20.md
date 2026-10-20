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

Next: connect existing Levels consumer to one corpus case with independent
output verification, then consider a small histogram/ROI analysis candidate
informed by the untouched research PR #77. No generic raster/storage
duplication and no API admission by this test-data PR.
