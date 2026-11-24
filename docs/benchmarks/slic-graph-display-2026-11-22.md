# Color SLIC, region graph and resident display — 2026-11-22

Baseline before these additions: `e091a3b886a259296cab99a0c4a7f32cfad57e7b`.
Implementation and exact-head CI are tracked in PR #205. This receipt concerns
the three requested engineering capabilities, not manually reviewed Dunia
interpretation, a stable API freeze or release publication.

Contracts: [SLIC/graph](../color-slic-region-graph.md),
[resident display](../resident-display.md), ADRs
[0020](../adr/0020-color-slic-owned-region-graph.md) and
[0021](../adr/0021-resident-display-specialization.md).

## Numerical and topological qualification

`tools/verify-region-program.py` drives a separately compiled public-module
consumer. Bulk NumPy Lab/space distances and centroid reductions independently
verify SLIC assignments, including every intermediate fixed-pass snapshot in
the iteration sweep. SciPy connected components and scan-order birth names
verify cleanup IDs. Pixel-derived means, population variances, spatial moments,
shared-side enumeration and independently merged label maps verify the graph.
RGB -> Lab D50 is independently checked with bulk transfer/matrix/Bradford/CIE
calculations, while production delegates all color conversion to color-d.

The full local corpus contains **60 cases / 86,334 domain pixels**:

- Patterned, random-color and constant images; blocks 1/7/256; RAM and windowed
  temporary files; origins above 2^53; fixed iterations 1..10.
- Spacing 1..32, compactness 1e-6..1e6, enabled/disabled seed perturbation and
  small-region cleanup. Empty/excluded masks, empty seed cells and disconnected
  islands are explicit. Four sparse-corner fixtures force eight orphan-fallback
  assignments and agree with the full-center reference.
- Generic graphs with sparse IDs, sorted neighbors, boundary evidence, chained
  merges, retained snapshots, original-label lineage and graph generations.
- Real Marchfeld crop (273,183,128,96), supplied as RGB8 and explicitly converted
  to Lab D50; three SLIC and three graph runs vary partition and backing.
  Original PNG SHA256:
  `4f60cb726ba7b9c6e993995598212bb681c05789ead5cec2f3272265b901289f`.

Assignments, canonical/final labels, adjacency, counts, bounds, perimeters,
lineage and all full-record partition/backing comparisons are exact. A cropped
label read is compared against finalized whole-domain labels. This does not
pretend that independent smaller-domain clustering has invariant global IDs.

Maximum absolute statistic error is **1.02318154e-12**, principally Lab population
variance. Mean/variance gates are `8e-15*abs(reference)+1e-13`; spatial covariance
uses `3e-15*abs(reference)+2e-13`, other region fields
`3e-15*abs(reference)+2e-14`. Finite boundary edge mean/variance use 3e-15
absolute. Mean-color contrast uses `1e-14*reference+8e-13`; its absolute allowance
accounts for subtracting independently rounded online means before the norm.
The near-zero/derived-field allowances are intentionally wider than the observed
roundoff where cancellation, merge order and supported backends can dominate;
these are regression gates, not a full-domain condition-independent error theorem.
Resolved angles agree modulo pi within 3e-12 rad; isotropic footprints must have
no resolved axis. RGB/Lab maximum is **1.66533454e-13 Lab units**, gate 5e-13.

There are 54 scene-independent cases in CI. Ordinary unittests additionally
exercise 13 SLIC failure/abort cases, 15 graph build/merge failures, prior graph
aliases, budget checks, invalid tags, overflow, final cancellation and D Error
propagation. The earlier 396 scene-independent component cases remain exact.

## Analysis memory and native timings

LDC 1.43.0 (DMD 2.113.0, LLVM 22.1.8), normal safe DUB release build,
Linux 6.17.0-22-generic x86-64, Intel i7-9750H, CPU affinity 0. Frequency, SMT,
desktop load and GC are not controlled. Test-only Python versions are pinned
in the requirement files: NumPy 2.5.5, SciPy 1.18.1, Pillow 13.0.0.

One warm-up cycle plus five measured cycles alternate forward/reverse order of
SLIC RAM/file and graph RAM/file. Source bytes/JSON parsing are outside native
timing. SLIC includes repeated color-d RGB/Lab conversion, assignment-scratch
setup, clustering, connected cleanup, graph construction/merging, final remap
and commit. Graph build/each merge have separate clocks; reference queries and
serialization are outside those clocks. Temp files are on **tmpfs**, buffered
without fsync, not a physical-disk or durability performance claim.

| Operation / backing | Median ms | Min..max ms |
|---|---:|---:|
| SLIC RAM | 60.1238 | 60.0532..72.5155 |
| SLIC temporary file | 118.3282 | 113.8658..127.7610 |
| Graph build RAM | 9.7495 | 8.7955..10.5740 |
| Graph build temporary file | 11.9340 | 11.7140..11.9809 |

The real SLIC crop has 192 active centers, 235,077 distance evaluations, no
orphan fallback and one cleanup round, yielding 194 connected regions. SLIC
work reservation is **5,219,160 bytes** under 8 MiB; observed GC bytes are
2,704,400 RAM / 2,705,328 file in this consumer. Prepared Lab providers can avoid
repeated conversion, but no unmeasured speedup is claimed.

The graph crop starts with 48 caller grid regions and 82 shared-side edges;
two adjacent merges leave 46 regions. Work reservation is **911,360 bytes**.
Median merge times are 0.3406/0.3048 ms (RAM) and 0.3209/0.3066 ms (file).
The oracle harness keeps a full RAM mirror for verification even in file mode;
that is not engine storage or a peak-RSS proof. Logical live payload excludes
providers, caller backing, GC headers and dead allocations awaiting collection.

Raw cycles are in [the region record](slic-graph-display-2026-11-22-regions.txt).

## Display target and limits

The real consumer is `tests/materialization --display`: actual imageio-d PNG
decode -> independent owned resident overview cache -> moving 512² viewport.
Decoder bytes are poisoned after copying into cache owners. Source revision
records the source content hash plus explicit overview/mask recipes. Overview
fixtures use Pillow BOX RGBA generation; this is a supplied source pyramid,
not qualification of an imagery-d pyramid-generation or color-management API.

Four modes are tested per scene: nearest at the selected overview grid,
fractional nearest, bilinear identity and area identity. All use the source's
adequate cached overview. Each output API (independent owned frame / scoped
private workspace) runs five loop warm-ups and **101 measured moving frames**.
Across synthetic mask/transparency data and three real scenes this is 3,232
measured frames. Final RGBA/validity for all 32 modes is independently exact
against Pillow/NumPy: **8,388,608 reference pixels**. Owned frame snapshots remain
unchanged; borrowed snapshots are explicitly copied before callback return.

The criterion is **p95 CPU assembly <=16.67 ms** on the recorded host. Source
decode/cache preparation, overview generation and consumer copy/GPU upload are
outside that clock. Individual outliers/maxima are retained: this is not a hard
real-time OS deadline guarantee. Arbitrary fractional bilinear/area, multiple
sources and cold decoding are not claimed to meet 60 fps.

Raw frame rounds and summary values are retained in
[the display record](slic-graph-display-2026-11-22-display.json). Work payload is
153,768 bytes and output 1,310,720 bytes. Real decoded source cache is 12,587,008
bytes, synthetic cache including masks 15,744,000 bytes, separately owned by the
provider. A warm private workspace allocates zero **output pixel payload**;
it still uses scratch allocation and observed small GC bookkeeping. This is
not an @nogc/allocation-free claim or a universal workspace latency speedup.

| Scene / output | Median range ms | p95 range ms | Largest frame ms |
|---|---:|---:|---:|
| deterministic-rgba-display / owned frame | 10.7315..11.1004 | 11.8943..14.5274 | 21.6076 |
| deterministic-rgba-display / private workspace | 10.9856..11.3368 | 11.8415..13.1789 | 22.7419 |
| marchfeld / owned frame | 9.4749..9.7880 | 10.6139..11.8809 | 20.3616 |
| marchfeld / private workspace | 9.7903..10.4960 | 11.7734..13.1539 | 20.0801 |
| wienerwald / owned frame | 9.5570..9.9694 | 10.8902..12.1293 | 22.1072 |
| wienerwald / private workspace | 9.9470..10.2783 | 10.5107..15.3543 | 20.9525 |
| semmering / owned frame | 9.8758..10.1671 | 11.0362..15.9423 | 19.8398 |
| semmering / private workspace | 10.0611..10.1887 | 11.8766..12.1601 | 20.2375 |

Ranges cover the four modes per row. All p95 values meet the recorded
16.67 ms target; the largest is 15.9423 ms. Observed GC bookkeeping per
measured frame is 240 bytes (owned) / 64 bytes (private workspace), separately
from C-backed pixel/scratch storage.

## General-filter regression investigation

The matched fractional synthetic benchmark retains old/new min/median/max,
provider calls, copied pixels, taps and checksums. Resident one-source nearest
changes from 65.6082 to 10.0079 ms, with 262,144 taps and the same checksum.
It copies zero cache pixels versus 2,229,282 before. Generated (newly allocated)
providers remain substantially more expensive than resident caches.

A general block-output trial did not uniformly improve other filters, so it
was rejected outside the direct path. Its [source patch](../research/display-block-output-prototype.patch)
and [diagnostic rounds](slic-graph-display-2026-11-22-prototype.txt) are retained.
Final workers specialize filter/ownership before their hot loops, keep invariant
plans local, inline cached taps and skip weight normalization for one positive
contributor. A permanent subnormal-factor test verifies that this last identity
does not exclude valid samples when the factor product underflows.

The final [candidate](slic-graph-display-2026-11-22-mosaic.txt) and
[baseline control](slic-graph-display-2026-11-22-control.txt) have unchanged
general-path taps/copy counts/checksums. Resident medians (baseline/candidate)
are 95.4659/83.3462 ms for one-source bilinear, 183.075/176.037 ms for one-source
area, 150.862/144.981 ms for three-source nearest, 233.397/223.115 ms for
three-source bilinear and 483.997/492.660 ms for three-source area. Last-case
distributions overlap; no small-effect speedup or thermal cause is inferred.
Earlier control drift was visible, and hardware counters were unavailable
(`perf_event_paranoid=4`). The generic work bound remains 6,029,952 bytes.

## Reproduction and gates

```sh
python -m pip install -r tests/component_regions/requirements.txt
dub build --root=tests/component_regions --compiler=ldc-1.43.0 --build=release
taskset -c 0 python tools/verify-region-program.py \
  tests/component_regions/component-regions-oracle --scene /path/marchfeld/esri.png --benchmark
dub build --root=tests/materialization --compiler=ldc-1.43.0 --build=release
taskset -c 0 python tools/verify-display.py tests/materialization/materialization-consumer \
  --scene /path/marchfeld/esri.png --workspace --require-60
dub build --root=tests/feature_program --compiler=ldc-1.43.0 --build=release
taskset -c 0 tests/feature_program/feature-program-oracle --mosaic-bench-fractional
bash tools/test-compiler-matrix.sh
DC=dmd-2.111.0 bash tools/verify-api-probes.sh
DC=ldc-1.43.0 bash tools/verify-api-probes.sh
DC=dmd-2.111.0 bash tools/build-docs.sh
```

Supported compiler gates cover default/no-io (27/26 unittest modules), named
@safe SLIC/graph/display consumers, readonly graph mutation and scoped callback
rejections, and rendered DDOX examples. CI runs all scene-independent references
and both display output APIs without imposing the host-specific wall-clock gate.
The complete human-reviewed Dunia application acceptance remains #187.
