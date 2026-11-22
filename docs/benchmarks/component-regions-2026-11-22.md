# Component-region qualification — 2026-11-22

Candidate: PR #205, after baseline `e0526de368346eb8f09b15978a0afd3febaac84f`.
This receipt qualifies the explicit caller-backed component contract, not all
of #186 or the human/application acceptance in #187. See
[ADR 0019](../adr/0019-transactional-component-regions.md) and
[public contract](../component-regions.md).

## Independent correctness

The separately compiled `tests/component_regions` consumer uses only public
direct-module imports. `tools/verify-component-regions.py` constructs the
complete pixel adjacency graph and traverses it with BFS, independently of the
production union/find. It names each component using the documented scan-order
birth rule. SciPy binary connected-components supplies a second partition check
when distance/cell/seed restrictions are absent. NumPy bulk reductions,
covariance eigendecomposition, explicit side counting and independent maximal
straight-run enumeration verify all remaining outputs.

The complete local corpus contains **400 cases / 146,964 pixels**:

- 384 mask/color graph cases: four patterns, 4/8 connectivity, seeded/unseeded,
  no color restriction/exact equality/distance .75/source cells of five,
  blocks 1/7/256 and RAM/file-backed labels. Origins above 2^53 exercise integer
  source-cell anchoring without converting global coordinates to double.
- 12 public image/canny adapter cases, including independently generated
  Sobel3x3/8, asymmetric four-sector NMS and seeded hysteresis. Validity,
  exclusion and independently missing texture/edge data are kept separate.
- Four real-scene cases, using blocks 16/127 and both label backings. Source
  Marchfeld `esri.png` SHA256:
  `4f60cb726ba7b9c6e993995598212bb681c05789ead5cec2f3272265b901289f`.
  Fixed crop (273,183,128,96), RGB/255 feature coordinates, single-link distance
  .12, 8-connectivity and source-anchored 16-pixel cells yield 133 regions.
  Edge is NumPy gradient magnitude of mean encoded channels; texture is squared
  mean. These are explicit test-provider features, not OKLab, learned semantic
  classes or manually reviewed truth.

Canonical labels, validity, contacts, line endpoints/counts, areas, bounds,
perimeters and finite coverage counts agree exactly. Full records, contacts and
lines also agree exactly across partitions and RAM/file storage. Every case
checks a 7×5 viewport read from finalized labels/validity against the full-domain
crop: 14,000 additional exact cropped label/validity positions. An independently
relabelled smaller domain is deliberately not promised to have the same IDs.

Maximum absolute mean/variance/auxiliary/evidence error was
**1.88737914e-15** on both DMD Debug and LDC Release; gate **2e-14**. This is
slightly above the workspace 10× review trigger: the small margin accommodates
online versus vectorized bulk reduction on 12,288-pixel domains and supported
compiler/platform variation. Topology remains exact. Resolved orientation is
checked modulo pi against eigendecomposition with a 3e-12 rad gate; exact
isotropic footprints must report no resolved direction. A permanent 7×7 square
regression prevents roundoff from inventing an axis.

Ordinary tests additionally cover **16 failure/no-publication scenarios**:
reader/writer/store/statistics/validity/contact exceptions, corrupt labels,
invalid states, color-statistics overflow, provisional-label exhaustion,
pre-read scratch rejection, a provider D Error, a fabricated `none` exception,
final-poll cancellation, invalid request and missing transaction callbacks.
Previously published arrays and aliases remain intact; D Errors run abort and
propagate. The documented success example commits a complete seeded component.

## Memory and runtime

Core engine payload is 400,208 bytes at labelLimit=1024, or **5,929,808 bytes**
at 16384 in the real-scene fixture, including its fixed row scratch. It is
checked before allocating. The largest real provider window is 128 pixels;
the API maximum is 258. Nothing allocates according to the entire source file.
Compact RAM label/validity payload for 128×96 is 49,152+12,288 bytes, separately
owned by the consumer. Disk staging can replace label RAM. Callback records,
contacts, source observations, GC headers and provider caches are not engine
scratch and must be budgeted by their owner.
The oracle harness retains a full-domain RAM mirror for JSON verification even
in file mode. That fixture proves windowed I/O correctness, not a peak-RSS or
zero-RAM claim for the test executable.

LDC 1.43.0 (DMD 2.113.0, LLVM 22.1.8), normal DUB release flags/safe checks,
Linux 6.17.0-22-generic x86-64, Intel i7-9750H. The process is pinned to CPU 0;
frequency, SMT and other desktop activity are uncontrolled. One warm-up plus
five pairs alternate RAM/file order. Full source feature preparation, JSON,
initial RAM/file backing setup and later line tracing are outside the clock.
Node allocation/initialization, both passes, callback record/contact growth,
validity and the transaction commit are inside it. No decoding is timed.

| Backing, block 16 | Median ms | Min..max ms | Observed GC bytes/call |
|---|---:|---:|---:|
| RAM staging | 2.9615 | 2.3151..21.4794 | 6,063,792..6,104,752 |
| Temporary-file staging | 9.2312 | 8.3596..32.5022 | 5,917,360 |

Raw rounds are retained in [the timing record](component-regions-2026-11-22.txt).
The large spread precludes a small-effect performance claim. Temporary files
were on **tmpfs**, buffered and without fsync: these results exercise file APIs,
not physical-disk bandwidth or crash durability. Record buffers have ordinary
GC growth; the operation makes no allocation-free/@nogc/nothrow claim. File-backed
line tracing performs many single-pixel reads and is not included in these times.

## Reproduction and gates

```sh
python -m pip install -r tests/component_regions/requirements.txt
dub build --root=tests/component_regions --compiler=dmd-2.111.0 --build=debug
python tools/verify-component-regions.py tests/component_regions/component-regions-oracle
dub build --root=tests/component_regions --compiler=ldc-1.43.0 --build=release
taskset -c 0 python tools/verify-component-regions.py \
  tests/component_regions/component-regions-oracle \
  --scene /absolute/path/to/marchfeld/esri.png --benchmark
bash tools/test-compiler-matrix.sh
DC=dmd-2.111.0 bash tools/verify-api-probes.sh
DC=ldc-1.43.0 bash tools/verify-api-probes.sh
DC=dmd-2.111.0 bash tools/build-docs.sh
```

The six supported compilers pass default/no-io, now 25/24 unittest modules.
DMD/LDC named @safe transaction probes and the additional DIP1000 direct label
escape rejection pass. Rendered DDOX includes the public error/result/transaction,
its fields and the executable staging example. CI runs the 396 scene-independent
reference cases on DMD and LDC; local scene fixtures remain external and hashed.

Remaining #186 work includes color-SLIC, richer durable region-graph integration
and complete Dunia scheduling/provenance/acceptance. Neither simple cell
segmentation nor scalar grid clustering is represented as color SLIC.
