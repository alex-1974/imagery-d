# M3 RGBA — owned result early-preflight performance qualification protocol

**2026-10-15 · Research Issue #74 · Design Issue #75 · Draft PR #73.**
**Status:** targeted *implemented* benchmark; **no XPS timing results admitted**.
No production API, merge, release or sibling repository writes are authorized.

## Concrete regression under study

[The preceding deterministic semantic-failure research]
(m3-rgba-preallocation-semantic-preflight.md)
moved the original prepared RGBA geometry/encoding/linear-PM
checks ahead of the first owned scratch `malloc`. This is
important on invalid input because it rejects before allocating
four-channel scratch and packed RGBA buffers.

For a valid **linear-premultiplied** source, however, the currently
strict research implementation scans the ROI **twice**:

1. once before the first scratch allocation;
2. again inside the existing destination-oriented prepared
   compositor, after scratch has been allocated.

Both scans check canonical source alpha/RGB bytes. The
former release benchmark had only the second one.

For **encoded-sRGB straight** input, the corresponding
source-only preflight is approximately descriptor/ROI checks:
there is no canonical linear-PM scan. That is a meaningful
control cohort, not a substitute for measuring linear-PM.

This protocol quantifies the extra operation *in the same
executable and same complete output-producing function*, with
the exact input fixtures and ROI sequences held constant.

## Code and comparison fairness

- Exact real consumer function:
  `experiments/m3_rgba_layer_compositing/smoke/source/app.d` private
  `tryCompositeOwnedPackedResearch` with a research-only optional
  `earlySourcePreflight=true` argument.
- **Old-order control:** `earlySourcePreflight=false`;
  the pre-existing prepared writer still performs its full
  canonical-PM/ROI preflight, **after** four-plane scratch
  `malloc`/public raster import. This recreates the older
  validation ordering within the same instrumented source.
- **New-order candidate:** `earlySourcePreflight=true`;
  all the old writer checks remain, plus an early nonallocating
  semantic preflight *before* scratch allocation.
- **Mechanism control:** direct
  `tryPreflightRgbaSourceOverPrepared` without output allocation;
  reports independent elapsed time but **must not be added
  to or subtracted from whole-call latency as a causal
  memory/throughput proof**.
- The old/new arms execute the identical `makeImage`,
  `tryCompositeRgbaSourceOverPrepared`, `makeOwnedPacked`,
  packing loop, public imports and final `RasterLease` release.
  Their sole intended logic difference is the early check.
  This is **not** an ABI or machine-code comparison to a
  separate historical commit; it isolates semantic work in
  one current binary. The optional flag is strictly a
  research-diagnostic mechanism; production uses the safe
  default and must **not** expose a public bypass of preflight.

### Correctness gates before/after any timing

For **all four changing offset ROIs**, create a prepared
caller-owned four-plane result and compare **every RGBA
channel of every resulting pixel** against both
independently materialized packed-result alternatives.
The original comprehensive 432-scene/51,840-byte independent
numerical oracle remains the separately required
correctness gate; this benchmark's comparison is an
in-process A/B equivalence check, not an independently
rederived Porter–Duff oracle.

For a valid source, both old/new results must have one
physical packed backing and exactly identical resulting
pixel values. A canonical FNV64 checksum of *the verified
four-ROI byte sequence* must remain constant across
rounds and source layouts for the same content.
For fully transparent **linear-PM** sources, initialize RGB
to zero when alpha is zero, preserving canonicality; for
encoded-straight transparent sources, intentionally retain
hidden RGB, as in the existing independent oracle.

## Paired benchmark matrix and controls

Independent XPS runner:
`tools/research/run_m3_rgba_owned_preflight_xps.sh`
with strict independent replay:
`tools/research/summarize_m3_rgba_owned_preflight_xps.py`.

The runner copies the actual *executable bytes*, immutable
`git archive HEAD` and pinned sibling **v0.2.0** source trees
to its ignored `data/` evidence directory. It records exact
LDC 1.43.0, DUB, XPS CPU/kernel/governors, Git commit hashes,
all run CSVs, build logs and SHA-256 manifest. The uploaded
archive **must retain the recorded consumer executable**;
the mutable live worktree and sibling HEADs are not sources
of the measured program. Ignore unrelated local dirty files
by building exclusively from committed snapshots.

| Axis | Smoke | Full native XPS |
|---|---|---|
| Compiler | LDC **1.43.0** Release | same |
| ROI side | 16, 64 | 16, 32, 64, 128, 256 |
| Input meaning | encoded-straight, linear-PM | same |
| Source layout | planar, interleaved | same |
| Alpha patterns | mixed | mixed, fully transparent |
| Source grid | 192² | 512² |
| Rotated ROI sites | four per run | four per run |
| Paired measurement rounds | 2 | 7 |
| Whole calls per timed stage/round | 2 | 24 |
| Distinct benchmark cases | **8** | **40** |
| Timed stages per case per round | old, new, isolated | same |

Each stage includes its ordinary call overhead and any
real native scratch/packed allocations, raster imports,
final lease close and error/return verification.
Prepared LUT construction and initial source-fixture
allocation occur **outside** timed rounds. Both variants
also receive the same warm-up calls.
The stage order rotates by round to mitigate systematic
drift, but a paired design cannot *eliminate* temperature,
frequency, allocator caching and GC variability. Report
observed CPU governor/frequency. No affinity or tuning
must be silently inferred if not explicitly set.

The CSV carries **nanosecond** stage durations, iteration
count, ROI pixels, source/alpha/layout tags, current-thread
GC allocation delta and the verified four-ROI pixel hash.
The independent summarizer verifies *all* expected
round-stage records, ordered rotation, input metadata,
identical byte-checksums between planar/interleaved,
SHA-256 of each input CSV and the archived executable,
then emits:

- absolute **old**, **new**, **standalone preflight**
  median ns/pixel;
- median **same-round new/old** ratio, signed same-round
  difference in ns/pixel, and min/max paired spread;
- separate GC allocation totals for each stage.

**No invented benchmark numbers:** prior native XPS reports
measured the earlier owned result and the caller-target
compositor, but they did **not** compare these two source
preflight orders within one executable. They must not
be quoted as measured overhead of the new early pass.
The C metadata allocator event sizes similarly do
not give performance timings.

## Decision rule and stop conditions

This is a **bounded attribution experiment**, not a
reason to develop another general cache/scheduler or
native RSS instrumentation. After checked XPS evidence,
record:

1. whether valid linear-PM ROIs suffer a repeatable
   consumer-visible latency penalty;
2. whether the source-only PM scan's observed cost
   is of comparable scale; check mixed vs transparent,
   small vs large ROIs and layout effects;
3. whether encoded-straight controls show similar
   movement (possible common-mode drift);
4. whether preflighting invalid input before malloc
   remains valuable, separately from valid-input timing;
5. whether a production solution must avoid the
   duplicate PM scan, and if so which *source
   ownership/immutability or short-lived validated
   capability* would make skipping revalidation sound.

A median old/new ratio more than **1.05** in an important
linear-PM workload is a **review trigger**, not an
automatic regression verdict or a public performance
guarantee. A ratio below that threshold does not certify
negligible cost where round noise is large; paired
distributions and end-to-end impact remain primary.

**Do not optimize away the second scan** by silently
trusting a stale borrower or by exposing an unchecked
public operation. The original four-plane prepared
destination API retains its own independent semantic
contract, including the demonstrated physical
noalias limitation.

Before claiming **PASS**, require all GitHub compiler
gates, the independent parser's --self-test and pinned
XPS --smoke. A full native XPS timing conclusion needs
a *user-supplied, independently checksummed* complete
--micro archive, not just a GitHub runner passing.
A binary/trace manifest omission, bad paired chronology,
changed source commits or unequal pixels invalidates
quantitative conclusions.

**Disposition at registration:** research ADAPT/MEASURE,
production/API admission DEFER. Retain PR #73 OPEN/DRAFT
on the grandfathered stacked base and Issues #74/#75 open.
