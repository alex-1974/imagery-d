# M3 RGBA — owned result early-preflight performance qualification protocol

**2026-10-15 · Research Issue #74 · Design Issue #75 · Draft PR #73.**
**Status:** targeted *implemented* benchmark; **no XPS timing results admitted**.
No production API, merge, release or sibling repository writes are authorized.

## 2026-10-15 XPS first-capture recovery receipt (not a benchmark result)

The user ran the runner on XPS from **measured immutable source**
`3b42a20845d5075f3d8a60613e404267a898c5ae`.
The **smoke** aborted after printing the first 192×192 encoded-straight
interleaved square16 case, but the submitted terminal output did not show
its per-case stderr/CSV or the reason for that early exit. No inference
about smoke validity is possible without those logs.

The separate **full 40-case native run**, output directory
`data/m3-rgba-owned-preflight-xps/20261015T200555Z`, printed every
scheduled case and `sha256sum -c CHECKSUMS.sha256` reported **OK for
all 40 raw CSVs, environment.txt, build.log and the exact measured
consumer binary**. Those are reports from the XPS terminal transcript;
the raw evidence archive was **not** provided at the time of this
diagnosis and has **not** been independently replayed here.

Both runs encountered the same **Python validation tool bug**:
`IndentationError: unexpected indent` at line 209 of
`tools/research/summarize_m3_rgba_owned_preflight_xps.py` inside
`self_test()`, because the expression for the synthetic manifest
filenames was split into an incomplete `sorted(...)` assignment
followed by an unparenthesized continuation. This is a Python parser
error **before** any real measurement could be independently summarized;
it does not establish a source-over numeric or performance defect.
The failed runner may leave an empty
`PREFLIGHT_COMPARISON.csv.tmp`; keep it as historical failed
analysis evidence rather than overwrite raw CSVs.

The syntax fix is on research commit
`78299af2d87f5b18c4673a26e020b60a1d55b885`.
Follow-up runner changes add per-case smoke failure diagnostics and
invoke the pinned immutable snapshot's `--self-test`
**before** collecting benchmark timings. Older measurements must
continue to cite their **original measured binary/commit**,
while any new analysis must additionally cite the *distinct*
fixed-validator source commit used for replay.

**Recovery path without repeated XPS timing:** verify the old
`CHECKSUMS.sha256` against the original full output directory,
run the fixed current validator against that directory and
write its derived `PREFLIGHT_COMPARISON.csv` as a new artifact,
leaving original raw CSVs, manifest, environment, executable
and its SHA unchanged. Confirm all **40 output rows** and preserve
the analysis-commit SHA separately. Re-run smoke only to
diagnose its early exit; the full run need not be repeated
if independent replay succeeds. Do not infer ratios or conclude
the >1.05 review threshold until actual complete raw evidence
and validated derived results have been inspected.

## Second XPS validator defect and no-rerun recovery (2026-10-15)

A **second** full native XPS run is present on the user's workstation at
`data/m3-rgba-owned-preflight-xps/20261015T211036Z`.
The supplied terminal excerpt shows original `environment.txt`,
`build.log` and the captured native consumer binary passing SHA-256.
Its immutable source snapshot's Python validator reaches the
`analyze()` stage, then rejects the first row file,
`512x512-encoded-straight-mixed-interleaved-square16.csv`,
with `missing successful all-pixel trailer`.

**Root cause is the research validator, not an observed failed image
oracle:** `runOwnedPreflightBenchmark()` writes a human-readable
success line containing **three literal commas**, which
`csv.reader` splits into **four fields**. The old validator
requires `len(rows[-1]) == 1`. The exact intended success receipt
is reconstructed using `",".join(rows[-1])` and checked for exact
content, while all fixed-width numeric measurement rows retain
their original strict 13-column validation. The validator's
synthetic self-test now uses the **exact four-field real receipt**,
not the former one-field `synthetic` message, and also mutates the
receipt while updating its SHA to verify that checksum validation
cannot mask a forged/incorrect success trailer.

**The XPS raw recording must not be overwritten or attributed to the
repaired source.** The fixed validator is an *analysis revision*;
the original `environment.txt` identifies the *different*
measured binary/commit. Use the added
`tools/research/replay_m3_rgba_owned_preflight_xps.sh`
on that existing output directory: it invokes the corrected
self-test, independently checks all existing manifest entries,
validates **40** paired cases, writes derived
`PREFLIGHT_COMPARISON.csv` only on a complete successful replay,
and writes a separate hashed `ANALYSIS_PROVENANCE.txt`.
It does not start new timings, change raw CSVs or overwrite any
existing derived final output. A stale `.tmp` from an earlier
failed analyzer is preserved as diagnostic evidence.

**Qualification status:** correction implemented on the active
research branch; exact-head CI and actual raw XPS replay are
separate gates and must not be reported green without their
respective evidence. Neither a physical memory budget nor a
numerical slowdown can be inferred from this traceback alone.

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
