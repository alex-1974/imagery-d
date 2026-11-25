# Accuracy and validation

Choose an operator by its declared input domain and numerical contract. The
source Ddoc defines units, edge handling, validity, precision and failure state;
one operation's guarantees must not be assumed for every other operation.

| Area | What to check before using a result |
| --- | --- |
| Scalar filters | Image shape, destination size, neighborhood/edge policy and supported finite input/scale domain |
| Tone mapping | Encoded versus linear values, selected channels, clipping and edit-mask role |
| Feature results | Descriptor units, sample validity and independent orientation validity |
| Float32 planes | Output conversion policy and any separately selected approximate arithmetic |
| Regions and graphs | Fixed analysis extent, connectivity, label identity and finite-observation counts |
| Mosaics | Caller registration, explicit filtering, alpha association, validity and source-quality facts |

The feature engine's ordinary output/arithmetic uses float64 where its contract
states that. Selecting float32 output does not silently select approximate
float32 intermediate arithmetic. `prepareGaussian32` is a separate choice with
its own finite normalized-domain error bound and fallback contract.

## Performance scope

The qualified 60-fps result applies to named resident 512-by-512 CPU display
workloads on the recorded host. It excludes decoding, network access, arbitrary
analysis and complete application latency. It is not a portable timing promise.
Optional x86-64-v3/native experiments do not raise the default CPU floor.

Use the [released benchmark guide](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/README.md)
to reproduce a named measurement. The
[Engine/Gaussian receipt](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/engine-gaussian-2026-11-24.md)
records source/compiler/host, precision, fixed admission limits and retained
raw/rejected cycles. The
[resident display receipt](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/slic-graph-display-2026-11-22.md)
defines the display-only timing scope.

Independent numerical references, layout/ROI tests, lifetime probes and
resource tests validate the declared operations. They do not establish a
scene-specific interpretation such as recognizing roads or buildings. The
application owns sensor calibration, geographic interpretation and decisions
about what a feature means in its dataset.
