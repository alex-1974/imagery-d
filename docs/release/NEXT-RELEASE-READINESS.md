# Next imagery-d source release — readiness outline

**Status (2026-10-29): preparation only; no version, release commit or tag
selected.** GitHub v0.1.0 is published from `5608e00`. imagery-d is not
registered on DUB. Registration is planned for v1.0.0 unless an earlier
consumer need requires it; registry publication is not a gate for the next
pre-1.0 GitHub source release.

## Candidate scope

The current `develop` source adds the accepted but unreleased ADR 0007–0011
RGB8 analysis, LUT and luminance-stretch APIs to v0.1.0 Levels. It requires
`raster-d ~>0.5.5` and `color-d ~>0.3.0`. M1/M2 source/cache experiments,
research-only RGBA/semantic-view branches and the M4 corpus tooling are not
production API admissions. A v0.2.0 minor release is the natural candidate
under the v0.1.0 pre-1.0 compatibility policy, but this outline does not
select a version or publish anything.

## Small release gate on the exact candidate

1. Exclude the unadmitted local combined LDC luminance experiment from the
   release candidate. Its independent byte oracle passes, but the valid
   paired complete-call repeat found no consistent performance gain.
2. Confirm Linux x86-64 DMD/LDC package, API/lifetime, consumer, Decimal,
   M4 P6 byte-oracle and Ddoc jobs on the exact release PR head. Compare
   the intended source archive, MIT license, manifest and public docs.
3. Qualify the luminance operator on the supported reference hardware with
   both mask modes and the declared worker budget. The currently recorded
   interactive goal is 30 frames/s (33.33 ms per 1080p full owned call);
   a 60 frames/s goal would be 16.67 ms and needs an explicit decision.
   Neither is a hosted-CI absolute timing gate.
4. Review user-facing source changes and dependency versions from v0.1.0,
   write short release notes, and prepare a version-specific tag publication
   workflow. The existing `publish-v0.1.0.yml` is specific to that tag.
5. Promote only through a reviewed PR to `main`; associate the resulting
   commit with its annotated version tag and publish the GitHub release.

Do not begin a release while the exact source candidate, version and
supported-platform evidence are unsettled. When DUB registration becomes
necessary, verify indexing with a clean registry consumer at that time.
