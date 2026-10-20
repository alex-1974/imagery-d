# imagery-d — M3 first release readiness (evidence as of 2026-10-20)

> **Decision update, 2026-10-20:** The first release version is now
> **v0.1.0**. The owner selected a *lean pre-1.0* policy. See
> [v0.1.0 release policy](PLAN-0.1.0.md) for **current** required gates,
> supported platform and the explicit choice **not** to create a separate
> release branch or internal freeze tags. This document preserves the
> earlier exploratory readiness inventory/receipts, including provisional
> items that are **no longer blockers** for v0.1.0. No release exists yet.


**Status:** RELEASE PREPARATION ONLY — **NO feature freeze, API freeze, tag,
main promotion, GitHub Release or DUB Registry publication authorized**.  
**Source baseline:** `develop` `b7a391722f23a4eb983a77fd7a28371a70d87444`
(squash-merged ADR 0005, ADR 0004, ADR 0006 and first `Levels` operator).
This document is a live release decision inventory, not evidence that
the future candidate has already passed the release gate.

## Version and compatibility recommendation

**Proposed initial version: `v0.1.0`; NOT ACCEPTED/CREATED.** A
pre-1.0 version is appropriate for a first API that has not survived a
published independent-consumer release cycle. Do not create a
`release/0.1` branch, `freeze/feature-0.1.0` or `freeze/api-0.1.0`
checkpoint until a deliberate **feature freeze** decision and its exact
baseline are recorded. A small first release might instead promote
`develop` through a full-gated release PR without a dedicated stabilization
branch (workspace Git workflow §3). No published release exists today.

**Validated Linux implementation** (as distinct from a promised support
policy): Ubuntu 24.04 x86-64, DMD 2.113.0/LDC 1.43.0 Debug+Release,
plus **the actual Levels root-package source and external archive
consumer** verified directly under DMD 2.111.0 and LDC 1.41.0. Exact
post-integration [Fast #39400671107](https://github.com/alex-1974/imagery-d/actions/runs/39400671107),
[M3 #39400671171](https://github.com/alex-1974/imagery-d/actions/runs/39400671171)
and new independent
[release-readiness matrix #39403627488](https://github.com/alex-1974/imagery-d/actions/runs/39403627488)
are SUCCESS.

**Discovered and closed compiler-floor evidence gap:** `dub.sdl`
declares `toolchainRequirements frontend=">=2.111.0"`, while
historical Fast CI compiled only the M2 experiment at DMD 2.111/LDC
1.41. The new independent Linux floor CI now directly builds/tests
the Levels package, ordinary consumer, `@safe`/DIP1000 compile contracts
and out-of-checkout source archive with both compilers.
**Both floor jobs completed SUCCESS** in
[readiness CI #39403627488](https://github.com/alex-1974/imagery-d/actions/runs/39403627488).
The result validates the tested versions, not every intermediate/future
frontend/compiler or platform version. LDC compiler and frontend
versions must continue to be distinguished.

**Platform investigation:** Ubuntu 24.04 x86-64 remains the only
platform with the complete oracle/DDox/performance release-candidate
evidence. Investigative macOS 15 and Windows 2025 DMD 2.113 / LDC
1.43 **all four passed their ordinary DUB build/test + Levels consumer
canaries** in readiness CI #39403627488. These are **nonblocking,
partial-scope canaries, not a full supported OS/architecture matrix**.
The full Ddoc, independent Decimal oracle, real P6 and archive tests
have not been qualified for each OS/compiler combination. Adopt a release
support policy only after choosing and running its complete gates.

## Gates and disposition

| Gate | Current evidence | Release decision |
|---|---|---|
| Domain + API boundary | ADR 0005/0004/0006 ACCEPTED on `develop`; minimal scalar Levels over raster-d-owned inputs | Source-qualified; no ABI freeze |
| Linux DMD/LDC primary matrix | 2.113.0/1.43.0 Debug+Release at exact `develop` `b7a3917` | PASS for tested Linux |
| Declared minimum frontend | Root package/independent consumer/DIP1000/archive passed DMD 2.111.0 and LDC 1.41.0 on Linux (readiness run #39403627488) | **PASS for these tested compilers only** |
| Broader supported platforms | macOS 15 and Windows 2025 DMD2.113/LDC1.43 build/test + ordinary consumer canaries all PASS | **OPEN** full release matrix and explicit support policy |
| Real DUB dependency | `raster-d@0.2.0` fetched from actual public DUB registry on fresh Ubuntu/DMD 2.113 with no local override; root package and ordinary Levels consumer PASS | **PASS clean registry consumption for tested Linux compiler** |
| Source package | MIT LICENSE and DUB manifest included, experiment/test trees export-ignored; clean archive consumer passed under 2.113/1.43 | PASS source archive, not registry package |
| Owned-result API | 624-case Decimal reference max observed 1 ULP, independent DUB/P6 consumers, standard failure/ownership tests | PASS sampled contracts, no global error bound |
| Ddoc/public API | Rendered Ddoc under DMD 2.113 at `develop` | PASS current docs, **full user tutorial remains pending** |
| Performance | Bounded LDC Release gamma2 same-run 3-way CPU-pinned smoke; candidate/sqrt 1.38–1.46 | PASS narrowly; no all-gamma/C++ parity |
| Repository baseline | LICENSE, README, CHANGELOG, ROADMAP, `dub.sdl`, GitHub CI; `CONTRIBUTING.md` added in this release-readiness PR | Partial; review release docs/version metadata |
| Publication gate | No v-tag, no main promotion or DUB package published. No release workflow qualified | **BLOCKED** pending explicit release decisions |

## Pre-release decisions still required

1. Resolve the first version candidate (`v0.1.0` proposed, not selected)
   and whether feature freeze/release branch is useful for this **small**
   first-release scope. No automatic branch/tag creation.
2. Compiler-floor evidence now passes on DMD 2.111.0 and LDC 1.41.0
   Linux; retain the declaration for this tested floor and decide the
   policy for intermediate/future compiler builds before release.
3. Decide supported OS/architecture policy. The platform canaries cannot
   establish portability of release packaging or full quality gates.
4. **Clean registry dependency gate completed on Linux:** real
   `raster-d@0.2.0` was fetched without `dub add-local` and passed
   the real imagery-d DUB build/tests and independent Levels consumer.
   Still independently verify the **imagery-d package's own** public
   registry publication and clean consumer **after** a future release.
5. Add a consumer-oriented tutorial/how-to, not just research proof, and
   verify Ddoc output and all contract statements match the final source.
6. Select and implement/qualify a separate **full release** workflow,
   promotion strategy and tagged publication workflow; review main branch
   protections and repository release settings. Do not make `main` point
   to an untagged release state.
7. Repeat full release candidate matrix, baseline performance/accuracy,
   archive and metadata/licence consistency at the **exact frozen source
   baseline**. Record evidence and checksums before promoting to `main`.

## Strict boundaries

No architecture changes, additional generic image operators, new
cache/scheduler framework, automatic semantic colour corrections, benchmark
threshold invention, silent front-end floor reduction, sibling-repository
writes or retroactive changes to grandfathered research PRs are authorized
by this readiness inventory.

The attached `Release readiness evidence` workflow has no tag, push,
upload-release, DUB publish, protected-branch write or credential privilege:
it only builds and reports results for a prospective **future decision**.

## New exact-head release-readiness receipts — 2026-10-20

[First workflow execution #39403627488](https://github.com/alex-1974/imagery-d/actions/runs/39403627488)
on `validation/m3-first-release-readiness` commit
`6094f77b027d9a53de0667b5fada14c30d43e0a4`: **6/6 jobs PASS**.

- Blocking **Linux floor**: DMD 2.111.0 and LDC 1.41.0 each passed
  `dub test`, Release `dub build`, independent ordinary DUB Levels
  consumer (48 cases/240 ROI outputs), `@safe`/DIP1000 positive and
  negative compile contracts, separately extracted `git archive` DUB
  consumer, and `M3_RELEASE_PACKAGE_PREFLIGHT=PASS`.
- **macOS 15** (DMD 2.113.0, LDC 1.43.0) and **Windows 2025**
  (DMD 2.113.0, LDC 1.43.0) all passed the nonblocking
  build/test/ordinary-consumer canaries. These jobs must remain labeled
  **partial-scope** until complete scientific/release gates are run.
- Existing [M3 #39403627360](https://github.com/alex-1974/imagery-d/actions/runs/39403627360)
  and [Fast #39403627353](https://github.com/alex-1974/imagery-d/actions/runs/39403627353)
  are also SUCCESS at the same first readiness head.

This closes the **declared floor gap** but does not select a release
platform/version, provide DUB registry publication evidence or freeze the
API. Future commits require their own exact-head checks.

## Clean DUB Registry dependency proof — 2026-10-20

[Release-readiness CI #39404629871](https://github.com/alex-1974/imagery-d/actions/runs/39404629871)
contains a separate **blocking** registry job on a fresh Ubuntu 24.04
runner with DMD 2.113.0 and DUB 1.40.0. The job does **not** check out
`raster-d` or execute `dub add-local`. It runs
`dub fetch raster-d@0.2.0`; the DUB log records:

- `Fetched package raster-d@0.2.0 successfully`
- cached package at `~/.dub/packages/raster-d/0.2.0/raster-d/`
- `Building raster-d 0.2.0` from the resolved dependency
- `M3_LEVELS_PRODUCTION_CONSUMER=PASS`
- `M3_RELEASE_REGISTRY_DEPENDENCY=PASS`

This demonstrates ordinary **dependency** resolution, build and
consumer execution without a local override. It does **not** mean
`imagery-d` itself has been registered, version-tagged or released.
