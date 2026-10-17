# M3 RGBA — independent XPS early-preflight paired-result review

**Research only · 2026-10-16 · Issue #74/#75 · Draft PR #73**
**Decision:** MEASURED/REVIEW duplicate PM scan; **NO production admission,
API freeze, merge, release or sibling repo changes**.

## Source identity and independent replay

The user supplied
`m3-owned-preflight-replayed-20261015T211036Z.tar.gz`
(SHA-256
`49e9dbc7d374004b9709f5fb7b6c0bb4139553a306861250af6def9be7be9700`).
The archive contains the real original native executable, build and
environment, 40 raw benchmark CSV files, all per-case resource/stderr logs,
original `CHECKSUMS.sha256`, and the subsequently generated analysis.

- **Measured imagery-d commit:**
  `01f02c0a5d52005620d5dabcf9e22aaf9e0de337`.
- **Analyzing/replaying imagery-d commit (NOT the measured binary):**
  `1e69f2ae734de6a4c71ad2568347ae9a306bd875`.
- Pinned read-only raster-d v0.2.0:
  `2f2415851e45001df92ce56dad409f680684ba8d`.
- Pinned read-only color-d v0.2.0:
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
- LDC 1.43.0 Release; DUB 1.42.0; XPS-15;
  Linux 6.17.0-22; recorded UTC `2026-10-15T21:10:36Z`.
  CPU governor reported `powersave`, current frequencies
  around 4 GHz at the environment snapshot.

Independent Python re-analysis was performed **without importing or
trusting the shipped summarizer**: enumerate each raw CSV, validate
its exact metadata/stage rotation/21 samples, recompute per-round
signed differences and ratios, medians, and cross-layout
pixel checksums; then compare every output column against
the submitted `PREFLIGHT_COMPARISON.csv`.

**Replay receipt:**
- **43/43** original SHA-256 manifest entries match; includes **40/40**
  CSV cases and archived compiled executable bytes.
- **2/2** derived analysis entries match, and the original
  manifest digest matches `ANALYSIS_PROVENANCE.txt`.
- **840/840** timed stage records pass shape, positive duration,
  pairing and stage-order checks (40 cases × 7 rounds × 3 stages).
- **40/40** independently recomputed summary rows agree, with no
  difference beyond the original six-decimal reporting precision.
- All 40 stderr files are empty; all 840 current-thread
  `GC.stats().allocatedInCurrentThread` deltas are zero.
  This is **not** an RSS, allocator/GC metadata or OOM guarantee.
- The 20 distinct meaning/pattern/ROI pixel hashes match across
  source physical interleaved/planar layouts. Valid-input old and
  new owned results were separately checked against all pixels
  of the prepared caller-owned destination in the original consumer.

The data archive originated from the user-provided XPS; this
commit records the independently verified analysis, **not**
new measurements performed in GitHub Actions.

## Scientifically relevant result

Three stages are compared: (a) entire owned materialization with
the previous allocation-before-PM preflight; (b) entire
owned materialization with **additional early** source-only
preflight before malloc, followed by the original PM preflight;
(c) the independent early preflight scan only.
They are distinct timing alternatives and **must not be
summed or subtracted** to create an estimated total.

**Cohort result**: median of 10 case-specific **paired**
7-round `early/old` medians per meaning/pattern cohort,
plus median of their signed per-pixel paired differences.
These are not pooled means, and not ratios of unrelated means.

| Meaning | Pattern | Median early/old | Signed median Δ ns/pixel | Standalone preflight median ns/pixel | Cases >5% slower |
|---|---|---:|---:|---:|---:|
| encoded-sRGB straight | mixed | 0.99404 (−0.60%) | −0.509 | 0.0046 | 0/10 |
| encoded-sRGB straight | transparent | 0.99921 (−0.08%) | −0.020 | 0.0041 | 1/10 |
| linear-sRGB PM | mixed | **1.06886 (+6.89%)** | **+6.413** | **6.172** | **8/10** |
| linear-sRGB PM | transparent | **1.20903 (+20.90%)** | **+6.200** | **6.350** | **10/10** |

The 20 linear-PM cases show 18/20 case-median slowdowns
above the protocol's **+5% review trigger**; the
encoded-straight control shows only 1/20.
Across linear-PM cases with medium/large ROIs,
the added time is generally **~5–7 ns/pixel**.
Transparent PM has a **higher ratio**, but similar
absolute per-pixel overhead, because its base
compositing path is much cheaper than mixed-alpha.
This is consistent with the duplicated full-ROI
canonical-PM scan, **not** proof that the source-only
timing can be arithmetically added to whole-call cost.

A secondary recomputation across all **70 round-pairs
per cohort** found signed slowdowns in 64/70 mixed-PM
and 66/70 transparent-PM pairs, versus 26/70
encoded-straight mixed and 32/70 encoded-straight
transparent. These round pairs are not 70
statistically independent whole-process replications.
Small (16×16) cases show substantial timing spread.
The +5% trigger means investigate/review, not
automatic production rejection or a claim that the
ratio generalizes to other CPUs.

## Consequence: optimize *contracts*, not just timers

**Accept the correctness and memory benefits of early
reject-before-malloc preflight for invalid input**, already
demonstrated in the independent consumer and native fault probes.
Do not make the existing early check optional in a public
API for arbitrary callers.

**Do not accept redundant full PM validation as free.**
For the minimal owned publication candidate, a single
full ROI canonical-PM check may suffice **only** if
it remains sound against source mutation/ownership and
any aliasing between check and use. Investigate a
short-lived, privately scoped same-call validated
execution path, or an immutable snapshot backed by a
sound owner/lifetime contract, **without** exposing an
unchecked public entry, silently assuming `@safe`
proves noalias or copying Research GenerationCache types
into production. A second typed copied preflight would
be a failed performance simplification. The existing
destination-oriented API's unchecked physical noalias
contract remains a separate Issue #75 blocker.

## CI caveat distinct from the 40-case XPS result

The latest preceding GitHub consumer workflow had
**LDC 1.42/1.43 smoke failures** in the benchmarking step
because, for encoded-straight with only **two**
preflight-only calls, optimized work could take
`0 ns` at the timer's effective resolution.
DMD's analogous jobs succeeded; the four other
workflow families passed. This **does not invalidate**
the 40-case user XPS data (24 iterations/stage, all
nonzero), but means the CI quality gate was not green.

A bounded research-only fix now allows `elapsed_ns=0`
**only for the standalone, encoded-straight preflight
control**, documenting it as a below-resolution,
censored timing observation. Both complete owned
call stages and linear-PM scans still require
positive durations; the independent parser's
synthetic self-test includes the censored case.
The new exact-head five-workflow CI remains
**pending**, not declared PASS until it completes.

## Remaining decisions

- Keep Issue #75's output-form, ownership,
  partial-output/alias and GC/error boundaries open.
- Before public admission, replace/avoid duplicated
  PM scans **only with a mechanically enforceable
  source consistency lifetime rule**, plus a repeat
  correctness oracle and native XPS performance proof.
- Do not conflate thread-local GC deltas, the 8N/4N
  requested-pixel quota, or these timing results with
  absolute resident process memory bounds.
- Preserve all original XPS raw artifacts and the
  **different source-versus-analysis commit identities**.

**Research disposition: ACCEPT performance evidence;
ADAPT minimal same-call PM validation design only after
ownership proof; DEFER public API, merge, release.**
