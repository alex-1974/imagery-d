# imagery-d M3 Levels — API admission review (2026-10-20)

> **Later admission decision (2026-10-20):** This is a dated,
> historically preserved **pre-admission** qualification inventory.
> ADR 0006 subsequently accepted the narrow Levels source API for
> `develop`, without an API/ABI freeze, release tag or registry publication.
> Original checkpoints and unsuccessful attempts remain as evidence.


**Status:** **DEFERRED — technical qualification succeeded, public API admission NOT authorized.**
This is a recommendation/decision inventory for the repository's actual
integration gate, **not an Accepted ADR, API freeze or release authorization**.

**Candidate:** [Draft PR #97](https://github.com/alex-1974/imagery-d/pull/97),
based directly on `develop` `f47c0ca521b89b526d6e943335bca57b773e08ef`.
The earlier candidate-selection priority was recorded on the separate
unmerged [Draft PR #96](https://github.com/alex-1974/imagery-d/pull/96)
(ADR 0004). The broader general-purpose scope clarification is separately
proposed in Draft PR #84; neither unmerged PR is silently incorporated here.

## Verified qualification

| Gate | Result and evidence |
|---|---|
| Independent consumer **from archive, outside checkout** | PASS. `tools/verify-archived-consumer.sh` creates a temp extraction using `git archive HEAD`, plus a separate DUB app outside the source checkout. The app depends only on the archive by relative DUB path and imports `imagery`. Tests @safe masked/unmasked calls, RGB gamma 2, owned result, budget error and prior-owner preservation. `raster-d` is an independently pinned and locally registered dependency. |
| Consumer archive surface and licensing | PASS. MIT `LICENSE`, DUB manifest and curated `source/imagery` are present. Tests, experiments, `.github` and `docs/research` are absent. This is **not** DUB registry packaging or a published package. |
| Baseline compiler support | PASS. DMD 2.111 / LDC 1.41 Fast CI; DMD 2.113 / LDC 1.43 Debug and Release candidate matrices, Ubuntu 24.04 (Linux x86-64). Neither macOS nor Windows acceptance is claimed. |
| D-language public contract | PASS for tested use. Both overloads directly callable from `@safe` consumers. Named args and UFCS compile-probed, `-preview=dip1000` local-owner escape rejected. Other negative probes reject unsupported `double` and non-public Into; removed `invalidDestination` cannot be imported. `LevelsError.init` is non-success `notAttempted`. |
| Numerical behavior | PASS for bounded sampled domain. DUB consumer validates u8/u16/f32, 48 combinatorial tests and 240 full/ROI outputs, failure publication, masked/unmasked, independent gamma oracles. A 624-case deterministic independent Python `Decimal` reference with precision 90 reported observed worst **1 binary32 ULP**. That is not a global one-ULP bound or bitwise NaN-payload policy. |
| Memory and ownership | PASS for normal returned errors and stated pixel budget. New interleaved ROI-local `RasterLease!float` is published only after complete success. Existing result preserved on normal returned errors; an output-owner/self-source alias regression passes. Payload budget excludes old result, source, metadata and process RSS. |
| Trusted memory boundary | PASS for compiler-qualified `@safe` declaration, using one reviewed private `@trusted` malloc/adoption helper and `raster-d`'s retained import contract. Does **not** imply `nothrow`, `@nogc`, fatal OOM-`Error` recovery, arbitrary exception-path promise or cross-thread mutation safety. |
| Image/file consumer | PASS. Separate P6 app reads/writes real image bytes, independent Python gamma2 byte oracle and no-overwrite failure checks. PPM remains in the consumer, not as an imagery-d runtime dependency. |
| API Ddoc / package docs | PASS on documented public entry points via rendered DDox and executable example; this document and README clarify draft status. |
| Representative LDC Release performance | PASS as narrow **gamma=2** optimization evidence. Paired same-run old generic pow, specialized sqrt reference and current owned-result candidate on 512×384 and 1024×768 masked RGBA show candidate/pow **0.120–0.128** and candidate/sqrt **1.38–1.46** across two hosted CPUs; full pixel comparison max absolute error 0 on the fixture. No generic-gamma, C++ parity, clock-fixed XPS or peak-RSS verdict. |

## Evidence scope and strict exclusions

The out-of-tree consumer is **authored and maintained by this repository**;
it proves a technically isolated **source-archive DUB package boundary**.
It does **not** prove third-party maintenance, registry propagation, or
ordinary `dub add` resolution of a published `imagery-d` version.

Only the declared current Linux compiler matrix is qualified.
A source-archive consumer is neither the same as a DUB Registry distribution
nor evidence that a published tag/version already exists.

API `@safe` covers D language memory-safety checks with a narrow documented
native trust boundary, not guaranteed success after a fatal OOM or another
`Error`. Error status `allocationFailure` is returned for detected failure
only; the package does not promise to catch arbitrary runtime exceptions.

The performance gate shows that the concrete gamma-2 optimized operation
avoids pathological generic Phobos pow cost and retains a residual
~38–46% distance to a simpler sqrt reference. It does not qualify all
gamma, all layouts, accelerated APIs, C++ parity or all processors.

## Remaining explicit decisions before admission to develop

1. **Architecture/priority integration order.** Review/decide the general
   image-processing boundary in Draft PR #84 and ADR 0004's first-operator
   priority in Draft PR #96. Treat them as actual separate changes with
   independent review, not as silently accepted statements in `develop`.
2. **Formal API-admission ADR verdict.** Record Accepted or Rejected of the
   exact public `Levels`, `LevelsError`, two `tryLevelsOwned` signatures,
   ROI/mask/input/output semantics, `@safe` with its `@trusted` obligation,
   publication, and explicit resource limit. A **DEFERRED** verdict does not
   complete the M3 exit gate.
3. **Version, toolchain and compatibility policy.** Choose a proposed first
   version, its DMD/LDC support scope, `raster-d` dependency/version policy,
   and source compatibility expectations. Do not represent current
   `toolchainRequirements` metadata as verified on every platform.
4. **Release-level qualification.** After API admission, qualify the exact
   promoted `develop`/release baseline, selected supported OS/architecture
   matrix, real release archive, version/CHANGELOG/docs and any planned DUB
   registry publication. Produce the release gate and deliberate signed/tag
   promotion only after authorization. Release process and `main` remain
   unmodified at this stage.
5. **Outstanding documentation hygiene.** Root `CONTRIBUTING.md` and a
   reader-oriented full tutorial may be added before release if required by
   the selected release policy; these are not prerequisites to demonstrate
   the isolated Levels call itself. Avoid speculative scaffolding.

## Current disposition

**The technical Levels candidate is sufficiently qualified for an explicit
public-API admission review, not for automatic integration or release.**
No public API is admitted to `develop` by this document, and no
`main`, `research-integration`, research PR, historical branch or release
tag is modified. All evidence remains reproducible from Draft PR #97.
