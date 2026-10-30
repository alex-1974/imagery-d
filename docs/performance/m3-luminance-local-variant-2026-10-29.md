# RGB luminance stretch — local combined candidate check

**Status:** correctness passes; combined optimization not admitted.

- Date: 2026-10-29
- Baseline: `9e16298` on `develop`
- Candidate: uncommitted `luminance_stretch.d` changes in the local checkout
- Compiler: LDC Release; DMD Release was used for unit tests
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: i7-9750H, `powersave`, benchmark affinity CPUs 0–3

The candidate combines direct lane decoding, a 2,048-interval LDC x86 output
table and an SSE reciprocal estimate with one Newton refinement. The last two
ideas had previously been rejected as isolated changes in the documented
whole-call experiments. A combined variant still needs its own evidence.

LDC and DMD Release unit tests passed. The independent 24-case P6 luminance
oracle passed for serial and parallel output with maximum one-byte error,
including masks, constant-bin identity and four rejected requests.

The first A/B/B/A complete-call comparison used the existing
`--parallel-luminance` consumer. Each process ran two warmups and seven
alternating timed pairs; results below are 1080p medians in milliseconds.

| Run | Variant | Serial unmasked | Serial masked | Four workers unmasked | Four workers masked |
|---|---|---:|---:|---:|---:|
| B1 | baseline | 38.876 | 40.604 | 18.210 | 16.058 |
| C1 | candidate | 40.267 | 36.853 | 19.569 | 19.413 |
| C2 | candidate | 39.366 | 38.888 | 15.381 | 13.586 |
| B2 | baseline | 40.639 | 38.594 | 17.251 | 15.226 |

Candidate-to-candidate parallel variation is larger than the apparent gain.
The serial results show no clear improvement. A later lane-decoding-only
comparison was invalidated when an unrelated `tiff-planar-large` process
occupied roughly eight to nine CPU cores across the same 0–11 CPU set; its
whole-call times rose above 100 ms. Hardware instruction counters were
unavailable (`perf_event_paranoid=4`).

After that process finished, a second A/B/B/A run used the same compiled
binaries, workload and CPU affinity. The baseline returned to the previously
documented 25–26 ms serial range. Its complete-call 1080p medians were:

| Run | Variant | Serial unmasked | Serial masked | Four workers unmasked | Four workers masked |
|---|---|---:|---:|---:|---:|
| B1 | baseline | 25.667 | 26.241 | 8.004 | 9.835 |
| C1 | candidate | 25.277 | 25.960 | 9.076 | 9.852 |
| C2 | candidate | 24.470 | 26.223 | 8.160 | 9.671 |
| B2 | baseline | 25.484 | 24.975 | 9.451 | 8.733 |

There is no consistent masked and unmasked whole-call gain over both process
orders. The additional x86-specific reciprocal and smaller table are not
admitted; the published `develop` implementation remains the baseline. The
combined local candidate was present before this investigation and remains
uncommitted for its owner to inspect.

The recorded interactive goal is 30 frames/s, or 33.33 ms per complete call;
60 frames/s would require 16.67 ms. Both include histogram, allocation and
transform. In the clean repeat both baseline four-worker modes were below
the 16.67 ms single-call threshold in both process orders. The baseline
serial path met 30 frames/s but not 60 frames/s on this host. These are
local medians, not a sustained-frame-rate or portable latency guarantee;
the first series shows how competing CPU work changes the outcome.
