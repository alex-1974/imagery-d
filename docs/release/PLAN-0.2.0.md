# v0.2.0 — RGB analysis and luminance source-release candidate

**Status:** candidate preparation; no `main` promotion, tag or publication.

v0.2.0 is the next minor source-release candidate. The version is appropriate
for the new public source APIs and dependency changes since v0.1.0 under the
pre-1.0 policy. Release admission remains conditional on the exact candidate
and its reviewed `main` PR; this plan does not authorize publication.

## Included source surface

- The published v0.1.0 scalar Levels API.
- ADR 0007–0010 RGB8 histogram/ROI statistics, cumulative counts and
  percentiles, percentile stretch LUT and equalization LUT.
- ADR 0011 RGB8 luminance percentile stretch with explicit ROI, optional
  threshold-selection mask, caller payload budget, ROI-local owned float
  result, clipping policy and explicit worker budget.

The source package requires `raster-d ~>0.5.5` and `color-d ~>0.3.0`.
M1/M2 research frameworks, experimental RGBA/ImageView branches, image
decoding, file I/O and the M4 corpus tools are not part of the public
source package. The uncommitted combined LDC kernel experiment is excluded;
its paired full-call comparison found no consistent gain.

## Release gate

On the exact release PR head, require the existing Linux x86-64 DMD/LDC
package, API/ownership, P6/Decimal/XYZ-D65-Y oracle, source-archive,
DDox, dependency-resolution and bounded Release performance checks. Reuse
the existing workflows; macOS/Windows remain best effort. Review README,
CHANGELOG, release notes, archive contents, dependency versions and public
Ddoc together. The local 1080p goal remains 30 fps (33.33 ms per full owned
call); a 60 fps target is not yet a release policy. Absolute hosted-CI time
is not a pass/fail criterion.

Prepare a reviewed PR into `main`. After its final merge commit is known,
associate that exact commit with one annotated `v0.2.0` tag and publish the
GitHub source release through the tag-only workflow. Do not leave a new
untagged `main` state. No DUB registration is planned before v1.0.0 unless
a concrete consumer need changes that policy.
