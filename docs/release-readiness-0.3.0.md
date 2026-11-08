# v0.3.0 release-readiness

## Public API

Consumer-facing names are the preferred interface: `gaussianBlur`,
`medianBlur`, `sobel`, `laplacian`, `canny`, `opening`, `closing`,
`connectedComponents`, `brightnessContrast`, `exposure`, `curves` and
`sourceOver`. Legacy or staged names remain available for compatibility and
advanced pipelines.

## Quality matrix

| Area | Required check | Status |
|---|---|---|
| Build | DMD release/unit tests | passing |
| Build | LDC release/unit tests | passing |
| Layout | ROI, signed stride, tile halo | covered by contracts; expand oracle coverage |
| Validity | alpha and NoData masks | covered for normalized difference/compositing |
| Algorithms | primitive unit/reference tests | passing baseline suite |
| Canny | FIFO vs Frontier pixel equality | covered |
| Performance | 1080p/4K focused benchmark | measured; results below |

## Measured baseline

DMD release-nobounds, 1920x1080:

```text
Gaussian: 57.045 ms median, 57.500 ms p95
Sobel:    67.984 ms median, 73.039 ms p95
Canny staged/frontier, 4 workers: 307.761 ms median, 322.439 ms p95
```

These are host-specific measurements. The interactive targets are 16.7 ms
for 60 fps and 30 ms as a fallback target; the current kernels do not yet
meet those targets.

## LDC qualification update

The same 1920x1080 / 4-worker benchmark under LDC release-nobounds measured:

```text
Gaussian parallel: 4.504 ms median, 5.827 ms p95
Sobel parallel:    1.408 ms median, 1.471 ms p95
8-bit preview:    19.930 ms median, 21.082 ms p95
Frontier Canny:   18.433 ms median, 20.457 ms p95
```

This meets the 30-ms target on the measured LDC host. It is not a universal
60-fps guarantee; consumers must benchmark their target CPU and compiler.

LDC release-nobounds, 3840x2160, 4 workers:

```text
Gaussian parallel: 24.268 ms median, 35.520 ms p95
Sobel parallel:     7.716 ms median, 12.862 ms p95
8-bit preview:     75.619 ms median, 83.220 ms p95
Frontier Canny:    94.195 ms median, 118.564 ms p95
```

The 30-ms target therefore applies to 1080p interactive processing, not to
full-resolution 4K Canny or preview processing.

## Release rule

Do not claim 60-fps support. A release may ship the API as a pre-1.0,
correctness-first release once the target-host LDC run and the expanded
signed-stride/ROI reference matrix are green.

## M5/M6 status — 2026-11-08

The current `develop` candidate additionally has reproducible DMD/LDC passes
for the regular decoded RGBA8 tile mosaic and explicit linear-light overlap
blend. Each has an independent oracle receipt in
`docs/qualification/m5-m6-qualification-2026-11-08.md`.

These passes do not close the release. Still required are real-image corpus
coverage, explicit NoData/source-quality semantics for production consumers,
expanded ROI/signed-stride oracles for the new public mosaic APIs, target-host
performance measurements, and the supported-platform matrix. M6 primitives
remain qualification-in-progress and ML adapters are not release scope.
