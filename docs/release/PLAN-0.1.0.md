# v0.1.0 — first release policy

**Decision:** `v0.1.0` is selected for the first release.
**Publication status:** **NOT RELEASED** (no tag or main promotion yet).  
**Date:** 2026-10-20  
**Tracking:** [Issue #99](https://github.com/alex-1974/imagery-d/issues/99)

## Small, practical pre-1.0 release

The owner explicitly chose v0.1.0 and proportionate checks below v1.0.
Do **not** turn the first release into another M3 research project.
This is a repository-specific **scope selection within** the canonical
workspace's release workflow, not an exemption from correctness, licence,
source-package or release-identity checks.

The version consists of the existing accepted **scalar owned-result
Levels API** (ADR 0006) with a curated MIT DUB package based on
`raster-d ~>0.2.0`. The generic M1/M2 source/cache framework,
additional operators, codecs and further numerical research are not
part of v0.1.0.

### Compatibility supported for v0.1.0

- **Supported release platform:** Linux x86-64. Ubuntu 24.04 is the
  tested baseline. The verified compiler combinations include
  DMD **2.111.0 and 2.113.0**, LDC **1.41.0 and 1.43.0**; the
  manifest's frontend floor remains `>=2.111.0`. The exact supported
  versions are evidence of these tested compilers, **not** a guarantee
  about every intervening/future compiler, CPU, or Linux distribution.
- **Best effort, not release-blocking:** macOS 15 and Windows 2025
  DMD 2.113.0 / LDC 1.43.0 ordinary-package/Levels consumer smoke.
  They passed nonblocking CI canaries, but they are not promised
  release platforms. Re-run manually when relevant; **do not** require
  a complete macOS/Windows differential/benchmark/DDox matrix.
- **Pre-1.0 stability:** `0.x` APIs may change before v1.0.
  Breaking changes should be called out in release notes and normally
  advance the minor version (0.1 -> 0.2); 0.1.x patch releases should
  avoid avoidable source-breaking changes. There is **no ABI promise**.

### Minimal release gate, reusing already integrated checks

On the **exact release candidate commit**, require:

1. Existing **Linux DMD/LDC** package build/unit/API and ownership
   regressions and ordinary consumer checks PASS. Reuse current Fast,
   Levels and floor CI; do not reimplement them as a fourth test suite.
2. The **existing** independent Decimal/oracle, P6/ROI and Ddoc gates
   remain green. No expanded universal 1-ULP theorem, external C++
   speed comparison, new benchmark corpus or repeated research campaign.
   Re-run performance qualification only if performance-relevant code
   has changed materially since the accepted evidence.
3. Real **`git archive`** includes MIT LICENSE, DUB manifest, public
   `source/` and user docs; excludes experiments/tests/internal release
   tracking. `raster-d@0.2.0` must resolve from a clean public DUB
   registry consumer (already demonstrated).
4. README, `CHANGELOG`, v0.1.0 release notes, public Ddoc and dependency
   metadata agree; no known release-blocking correctness/ownership defect.
5. Reviewed PR promoting this qualified exact `develop` source to
   **`main`**. Associate that final `main` state immediately with
   an annotated **`v0.1.0`** release tag, not a `freeze/*` tag.
   Publish GitHub Release/release notes; verify the actual DUB package
   entry after it becomes available. Record the release commit/CI URLs.

No separate `release/0.1` branch, `freeze/feature-0.1.0`,
`freeze/api-0.1.0` or extra API-freeze audit is required for this
**small** first pre-1.0 release. The release tag is the immutable
published-source reference. Both `main` and the release tag are
still **untouched** at this planning stage.

**Not a release approval:** selecting a version and slim gates does not
instruct anyone to create `v0.1.0`, change `main`, publish to
DUB or generate release credentials. These remain deliberate actions.

## Existing evidence — no unnecessary requalification

The accepted Levels source and ADR 0006 are in `develop`
`b7a391722f23a4eb983a77fd7a28371a70d87444`. The first
readiness tools were integrated at
`c7a31d9e42fe5cb6702eccb1fdde9b7102d46ca4`.

- [M3 Levels exact-head gate #39405730345](https://github.com/alex-1974/imagery-d/actions/runs/39405730345)
  (independent oracle, consumers, Ddoc, bounded LDC performance): PASS.
- [Fast CI #39405730376](https://github.com/alex-1974/imagery-d/actions/runs/39405730376): PASS.
- [Release readiness #39405730340](https://github.com/alex-1974/imagery-d/actions/runs/39405730340):
  Linux floor DMD2.111/LDC1.41 and clean registry dependency: PASS.
- [Four macOS/Windows canaries on PR #98](https://github.com/alex-1974/imagery-d/actions/runs/39405226407):
  all PASS; partial-scope and informational only.

The earlier [readiness research/evidence inventory](READINESS-0.1.0.md)
is retained as dated material; any provisional "must evaluate full OS
matrix" or freeze-branch requirements in it are superseded by **this
explicit v0.1.0 decision**.
