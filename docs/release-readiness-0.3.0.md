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
| Build | LDC release/unit tests | pending target-host run |
| Layout | ROI, signed stride, tile halo | covered by contracts; expand oracle coverage |
| Validity | alpha and NoData masks | covered for normalized difference/compositing |
| Algorithms | primitive unit/reference tests | passing baseline suite |
| Canny | FIFO vs Frontier pixel equality | covered |
| Performance | 1080p/4K focused benchmark | available in `tests/perf_primitives` |

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

## Release rule

Do not claim 60-fps support. A release may ship the API as a pre-1.0,
correctness-first release once the target-host LDC run and the expanded
signed-stride/ROI reference matrix are green.
