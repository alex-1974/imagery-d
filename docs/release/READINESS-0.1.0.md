# imagery-d — M3 first release readiness (evidence as of 2026-10-20)

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

**Current tested implementation** (as distinct from a promised support
matrix): Ubuntu 24.04 x86-64, DMD 2.113.0/LDC 1.43.0 Debug+Release
plus separate legacy M2 Fast gates DMD 2.111.0/LDC 1.41.0. Exact
post-integration [Fast #39400671107](https://github.com/alex-1974/imagery-d/actions/runs/39400671107)
and [M3 #39400671171](https://github.com/alex-1974/imagery-d/actions/runs/39400671171)
are SUCCESS.

**Unverified compiler-floor claim discovered in preflight:** `dub.sdl`
declares `toolchainRequirements frontend=">=2.111.0"`, but the
repository's existing Fast CI only compiled the M2 experiment with
DMD 2.111.0 and LDC 1.41.0. It did **not** compile the new root Levels
DUB package under these versions. The attached **Linux floor CI** now
builds/tests the actual package, an ordinary consumer, the DIP1000
compile-only contract, and the out-of-checkout source archive under those
exact compilers. **Do not claim the floor is supported until the new
matrix passes.** For LDC, the compiler version does not necessarily equal
the D frontend version; verification must distinguish them.

**Platform proposal:** keep **Linux x86-64 as the only empirically
qualified platform for now**. macOS 15 and Windows 2025 DMD/LDC are
investigative **nonblocking canaries**, not claims of support; assess
their build and linker errors separately before setting first-release
OS/architecture support. The supported platform/compiler matrix
must be explicitly decided *before* a release candidate is accepted.

## Gates and disposition

| Gate | Current evidence | Release decision |
|---|---|---|
| Domain + API boundary | ADR 0005/0004/0006 ACCEPTED on `develop`; minimal scalar Levels over raster-d-owned inputs | Source-qualified; no ABI freeze |
| Linux DMD/LDC primary matrix | 2.113.0/1.43.0 Debug+Release at exact `develop` `b7a3917` | PASS for tested Linux |
| Declared minimum frontend | Fast 2.111.0/1.41.0 only tested historical M2; *new release floor workflow must test Levels itself* | **OPEN until gate PASS** |
| Broader supported platforms | No claimed macOS/Windows production support; nonblocking platform canaries introduced | **OPEN**; decide scope after evidence |
| Real DUB dependency | `raster-d ~>0.2.0`; raster-d `v0.2.0` is published (2026-10-10); CI pins exact SHA `2f241585...` in a local registry | Version 0.2.0 exists; **normal clean remote/registry resolution unverified** |
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
2. Decide actual minimum compiler frontend based on direct root + archived
   external consumer gates; verify metadata matches that decision.
3. Decide supported OS/architecture policy. The platform canaries cannot
   establish portability of release packaging or full quality gates.
4. Audit normal registry-sourced `raster-d ~>0.2.0` resolution from a
   clean remote consumer (no `dub add-local`) before claiming the same
   install behavior for release dependencies; independently verify
   published `imagery-d` from the registry **after** publication only.
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
