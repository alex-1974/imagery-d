# Engine publication and bounded Gaussian derivatives

Refs #212, #216, #217. Functional qualification and fixed performance admission are separate.

Candidate binary source: `fcbd95e236efbe5ff90a90bd5792a890f6f3d09b`; baseline: `118c06f1d63bdd49c90eeaed19ad3bc1c2c115d3`.
The baseline is develop 118c06f with identical benchmark sources and measurement-only planar phase clocks. Both Engine transports read the same precomputed Float64 raster; fixture generation and hashing are outside clocks.
Compiler: LDC 1.43.0; portable, x86-64-v3 and native targets, default strict arithmetic and bounds policy. Host: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz.

All paired receipts require >=15 accepted complete ABBA cycles, 4,000 whole-cycle bootstrap draws, median/MAD and a 10% minimum conclusive effect. Endpoint frequency movement >5%, load >6, governor/power changes or SMT sibling activity >5% reject whole cycles. No timing-based rejection or control normalization. Collection caps and all rejected cycles are retained. Repository builds and other repository suites do not run concurrently with paired collection.
The host uses powersave with turbo enabled; frequency controls were not writable. No privilege escalation or relaxed hygiene limits were used.

Comparisons apply within each named paired cell. Separate mode/ISA medians are not matched mode/ISA experiments. The kernel tables compare source revisions at identical target flags; they do not re-admit the older-source ISA experiment.

The final collection pins CPU 0, uses a declared 600-second/90-cycle cap per source-comparison cell and at most five 15-cycle batches per Engine/worker setting. Earlier candidates and noise-limited runs remain stage-specific diagnostics; final admission uses the complete qualified rows for this candidate.

## Prepared Gaussian kernels

Finite Float32 fixture, 1024², Hessian scales 1,2,4 and default tensor parameters. Only the prepared evaluation is clocked; complete channel/mask hashes must agree at each identical target.

| Feature / target | After ns/px ± MAD | Before ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect | Absolute Hessian gate |
|---|---:|---:|---:|---:|---|---|
| hessian/portable | 241.603 ± 6.033 | 398.331 ± 4.092 | 0.598 [0.596, 0.612] | 15/4 | improvement | pass [235.553, 245.526] |
| hessian/v3 | 217.597 ± 2.520 | 428.563 ± 5.119 | 0.515 [0.503, 0.522] | 15/1 | improvement | pass [216.013, 222.085] |
| hessian/native | 219.497 ± 3.587 | 393.389 ± 3.442 | 0.559 [0.551, 0.567] | 15/10 | improvement | pass [215.910, 223.616] |
| tensor/portable | 76.852 ± 1.361 | 136.522 ± 1.893 | 0.571 [0.558, 0.579] | 15/10 | improvement | — |
| tensor/v3 | 68.916 ± 1.260 | 137.483 ± 0.958 | 0.499 [0.495, 0.510] | 15/4 | improvement | — |
| tensor/native | 68.913 ± 0.895 | 110.135 ± 2.065 | 0.614 [0.611, 0.628] | 15/4 | improvement | — |

The fixed first Hessian ceiling is 325 ns/px. A true twofold improvement from the historical 414.169 ns/px portable receipt would need about 207 ns/px; these are separate targets. No Float32 intermediate, tap folding, recursive Gaussian or approximate exp/atan2 is introduced.

### Block selection and owned payload

Descriptive sweep source: `6f6a6c0f4f197b0febbfc34a9619e59551a46306`; block dimensions are explicitly overridden in every cell.

The descriptive sweep rotates 15 shapes across three rounds, with identical output fingerprints and zero GC bytes. Its observations tune storage; they do not admit a performance target.

| Feature / rows × width | Sweep median ns/px | MAD | Owned bytes |
|---|---:|---:|---:|
| hessian/32×128 | 283.525 | 1.286 | 196608 |
| hessian/64×128 | 251.656 | 4.993 | 294912 |
| hessian/128×128 | 242.292 | 0.163 | 491520 |
| hessian/128×256 | 241.242 | 0.184 | 983040 |
| tensor/32×128 | 76.760 | 1.428 | 304896 |
| tensor/64×128 | 74.265 | 0.366 | 516864 |
| tensor/128×128 | 73.067 | 1.891 | 940800 |
| tensor/128×256 | 73.751 | 1.328 | 1813248 |

Hessian defaults to 128×128 (491,520 bytes at this scale envelope), tensor to 32×128 (304,896 bytes). Prior full-plane payloads are 33,554,432 and 50,331,648 bytes. Legacy reserve(samples) still retains full-plane capacity; reduced storage requires shape-aware reserve. Caller input/output, weights, metadata and fixed row stacks (6 KiB Hessian, 7 KiB tensor) are additional. The Engine 8 MiB tile-payload contract is checked independently; these standalone workspaces are not RSS claims.

### Deterministic simulated-cache companion

Model: `--I1=32768,8,64, --D1=32768,8,64, --LL=8388608,16,64`, 256², one prepared frame after preheat.

| Feature/source/block rows | Instructions | D1 misses | LL misses |
|---|---:|---:|---:|
| hessian-before-0 | 301671500 | 1435696 | 0 |
| hessian-after-32 | 194699346 | 1564179 | 0 |
| hessian-after-64 | 170366234 | 1535171 | 0 |
| hessian-after-128 | 158231970 | 1525828 | 0 |
| tensor-before-0 | 95978059 | 239654 | 0 |
| tensor-after-32 | 55353482 | 508249 | 0 |
| tensor-after-64 | 50760610 | 481497 | 0 |
| tensor-after-128 | 48464174 | 468096 | 0 |

At the full 1024² admission footprint, use the selected Hessian 128×128 and tensor 32×128 blocks:

| Feature / source | Instructions | D1 misses | LL misses |
|---|---:|---:|---:|
| hessian-before | 4852593933 | 28533737 | 6207901 |
| hessian-after | 2410918098 | 25042574 | 1067274 |
| tensor-before | 1565452991 | 9995947 | 3784843 |
| tensor-after | 826942654 | 8380840 | 300476 |

Both instruction work and simulated traffic change. The 256² carrier fits a different cache regime from 1024²; report both rather than extrapolating small-tile misses. These fixed-model observations do not isolate a pure memory-bandwidth bottleneck or measure real hardware misses. Reduced instruction work and bounded working storage are joint mechanisms; no tolerance-changing approximation is needed.

## Engine before/after, complete output and view publication

Full modes include callback materialization into three Float32 planes and three masks. View-only modes count delivered samples, then independently materialize and hash the same fixture outside the clock. Fresh cold instances and changing warm revisions prevent cache-hit replay. Warm rows must allocate zero thread-GC bytes.

| Feature / mode | After ns/px ± MAD | Before ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect |
|---|---:|---:|---:|---:|---|
| gaussian/cold64 | 22.575 ± 0.705 | 31.579 ± 0.888 | 0.711 [0.693, 0.729] | 15/8 | improvement |
| gaussian/cold32 | 11.133 ± 0.210 | 21.015 ± 0.666 | 0.545 [0.513, 0.554] | 15/21 | improvement |
| gaussian/warm | 9.226 ± 0.241 | 18.633 ± 0.690 | 0.494 [0.473, 0.505] | 15/4 | improvement |
| gaussian/cold64-view | 11.006 ± 0.300 | 21.077 ± 1.005 | 0.516 [0.505, 0.541] | 15/13 | improvement |
| gaussian/cold32-view | 9.269 ± 0.337 | 19.243 ± 0.815 | 0.482 [0.469, 0.507] | 15/20 | improvement |
| gaussian/warm-view | 6.720 ± 0.088 | 15.622 ± 0.347 | 0.435 [0.414, 0.444] | 15/16 | improvement |
| gradient/cold64 | 63.005 ± 1.275 | 72.156 ± 1.329 | 0.878 [0.848, 0.889] | 15/16 | improvement |
| gradient/cold32 | 53.157 ± 0.979 | 62.722 ± 1.385 | 0.839 [0.826, 0.890] | 15/8 | improvement |
| gradient/warm | 48.754 ± 0.726 | 58.339 ± 1.132 | 0.833 [0.805, 0.874] | 15/4 | improvement |
| gradient/cold64-view | 52.061 ± 0.704 | 61.366 ± 1.320 | 0.841 [0.833, 0.853] | 15/2 | improvement |
| gradient/cold32-view | 49.458 ± 0.670 | 59.466 ± 0.556 | 0.833 [0.815, 0.844] | 15/8 | improvement |
| gradient/warm-view | 44.968 ± 0.427 | 54.374 ± 0.407 | 0.828 [0.820, 0.851] | 15/1 | improvement |
| median/cold64 | 21.145 ± 0.507 | 30.796 ± 0.849 | 0.681 [0.671, 0.704] | 15/35 | improvement |
| median/cold32 | 10.193 ± 0.316 | 19.953 ± 0.517 | 0.508 [0.501, 0.522] | 15/19 | improvement |
| median/warm | 7.800 ± 0.162 | 16.937 ± 0.419 | 0.454 [0.444, 0.472] | 15/5 | improvement |
| median/cold64-view | 9.525 ± 0.221 | 19.071 ± 0.688 | 0.510 [0.485, 0.524] | 15/5 | improvement |
| median/cold32-view | 7.705 ± 0.133 | 17.799 ± 0.183 | 0.435 [0.417, 0.442] | 15/11 | improvement |
| median/warm-view | 5.552 ± 0.151 | 14.748 ± 0.645 | 0.374 [0.366, 0.380] | 15/11 | improvement |
| ridge/cold64 | 87.708 ± 1.301 | 95.981 ± 1.471 | 0.911 [0.898, 0.923] | 15/10 | inconclusive |
| ridge/cold32 | 65.554 ± 0.337 | 77.717 ± 0.450 | 0.847 [0.837, 0.857] | 15/7 | improvement |
| ridge/warm | 61.452 ± 0.209 | 72.173 ± 0.791 | 0.849 [0.849, 0.865] | 15/8 | improvement |
| ridge/cold64-view | 75.515 ± 0.838 | 84.203 ± 0.960 | 0.900 [0.866, 0.914] | 15/1 | improvement |
| ridge/cold32-view | 63.650 ± 0.787 | 75.173 ± 1.707 | 0.865 [0.827, 0.875] | 15/7 | improvement |
| ridge/warm-view | 59.032 ± 0.603 | 69.167 ± 0.795 | 0.854 [0.846, 0.874] | 15/5 | improvement |
| gabor/cold64 | 316.822 ± 3.279 | 324.824 ± 1.482 | 0.974 [0.964, 0.985] | 15/7 | inconclusive |
| gabor/cold32 | 357.523 ± 4.111 | 364.019 ± 5.524 | 0.982 [0.978, 0.988] | 15/4 | inconclusive |
| gabor/warm | 357.824 ± 3.407 | 360.034 ± 2.478 | 0.993 [0.983, 1.005] | 15/23 | inconclusive |
| gabor/cold64-view | 308.664 ± 2.620 | 314.855 ± 3.015 | 0.970 [0.964, 0.994] | 15/16 | inconclusive |
| gabor/cold32-view | 358.865 ± 3.819 | 362.688 ± 2.690 | 0.992 [0.985, 0.999] | 15/11 | inconclusive |
| gabor/warm-view | 351.938 ± 3.901 | 356.087 ± 3.916 | 0.989 [0.985, 0.990] | 15/9 | inconclusive |

## Separate instrumented phases

These clocks come from ImageryProfile binaries, separately from ordinary release time. Source is provider transport exclusive of the nested borrowed-plane pack. Preparation packs and validates; cache publishes completed buffers; sink surrounds the actual callback. AoS record construction remains kernel/output work. Required output initialization remains in rendering. Spare buffers use Phobos minimallyInitializedArray, removing a redundant default NaN/zero fill before the full active-extent initialization. First-touch costs occur where the writes execute; outer clocks retain the complete work. Phase sums need not equal the outer timer.

| Feature / mode | Source ns/px [95%] | Prepare | Cache | Sink | Sum | Accepted/rejected |
|---|---:|---:|---:|---:|---:|---:|
| gaussian/cold64-view | 0.006 [0.006, 0.006] | 3.068 [2.956, 3.199] | 2.670 [2.541, 2.829] | 0.008 [0.006, 0.008] | 5.738 [5.525, 6.053] | 15/11 |
| gaussian/cold32-view | 0.003 [0.003, 0.004] | 2.930 [2.858, 3.042] | 0.328 [0.313, 0.357] | 0.001 [0.001, 0.001] | 3.278 [3.174, 3.414] | 15/13 |
| gaussian/warm-view | 0.003 [0.002, 0.003] | 2.734 [2.700, 2.790] | 0.004 [0.004, 0.005] | 0.000 [0.000, 0.000] | 2.742 [2.706, 2.798] | 15/4 |
| gradient/cold64-view | 0.009 [0.008, 0.010] | 3.004 [2.958, 3.234] | 5.891 [5.759, 6.483] | 0.012 [0.011, 0.015] | 8.946 [8.738, 9.598] | 15/10 |
| gradient/cold32-view | 0.002 [0.002, 0.002] | 2.466 [2.424, 2.528] | 0.587 [0.556, 0.593] | — pending | 3.029 [3.013, 3.119] | 15/3 |
| gradient/warm-view | 0.002 [0.002, 0.002] | 2.402 [2.369, 2.461] | 0.005 [0.004, 0.005] | — pending | 2.408 [2.376, 2.470] | 15/0 |
| median/cold64-view | 0.003 [0.002, 0.003] | 2.564 [2.559, 2.611] | 1.950 [1.905, 2.001] | 0.003 [0.003, 0.003] | 4.520 [4.481, 4.622] | 15/11 |
| median/cold32-view | 0.002 [0.002, 0.002] | 2.479 [2.434, 2.562] | 0.073 [0.057, 0.224] | 0.000 [0.000, 0.000] | 2.647 [2.551, 2.733] | 15/2 |
| median/warm-view | 0.002 [0.002, 0.002] | 2.421 [2.315, 2.634] | 0.003 [0.003, 0.003] | — pending | 2.426 [2.319, 2.640] | 15/0 |
| ridge/cold64-view | 0.003 [0.003, 0.004] | 2.672 [2.650, 2.747] | 3.071 [2.886, 3.548] | 0.004 [0.003, 0.004] | 5.876 [5.636, 6.263] | 15/2 |
| ridge/cold32-view | 0.002 [0.002, 0.002] | 2.548 [2.511, 2.616] | 0.597 [0.593, 0.605] | 0.000 [0.000, 0.000] | 3.145 [3.115, 3.217] | 15/1 |
| ridge/warm-view | 0.002 [0.002, 0.003] | 2.613 [2.498, 2.986] | 0.003 [0.003, 0.004] | — pending | 2.619 [2.504, 2.995] | 15/2 |
| gabor/cold64-view | 0.005 [0.004, 0.006] | 2.799 [2.761, 2.824] | 7.098 [7.017, 7.217] | 0.006 [0.006, 0.007] | 9.935 [9.739, 10.053] | 15/0 |
| gabor/cold32-view | 0.004 [0.003, 0.004] | 2.877 [2.771, 3.093] | 0.058 [0.055, 0.061] | — pending | 2.936 [2.837, 3.155] | 15/0 |
| gabor/warm-view | 0.003 [0.003, 0.003] | 2.591 [2.570, 2.618] | 0.005 [0.004, 0.005] | — pending | 2.600 [2.577, 2.626] | 15/1 |
| gaussian/cold64 complete frame | 0.003 [0.003, 0.004] | 2.575 [2.538, 2.639] | 3.227 [2.488, 3.617] | 10.130 [10.090, 10.249] | 16.052 [15.480, 16.391] | 26/4 |
| gaussian/cold32 complete frame | 0.003 [0.002, 0.003] | 2.574 [2.533, 2.617] | 0.162 [0.102, 0.214] | 1.718 [1.710, 1.743] | 4.525 [4.424, 4.585] | 28/2 |
| gaussian/warm complete frame | 0.002 [0.002, 0.002] | 2.540 [2.516, 2.576] | 0.003 [0.003, 0.003] | 1.630 [1.621, 1.658] | 4.183 [4.152, 4.231] | 29/1 |
| gradient/cold64 complete frame | 0.004 [0.004, 0.004] | 2.552 [2.539, 2.594] | 3.162 [2.969, 3.575] | 10.090 [10.045, 10.209] | 16.127 [15.840, 16.571] | 29/1 |
| gradient/cold32 complete frame | 0.003 [0.003, 0.003] | 2.522 [2.497, 2.567] | 0.056 [0.035, 0.106] | 1.890 [1.871, 1.913] | 4.767 [4.586, 4.818] | 30/0 |
| gradient/warm complete frame | 0.003 [0.003, 0.003] | 2.520 [2.504, 2.538] | 0.005 [0.005, 0.005] | 1.829 [1.818, 1.852] | 4.354 [4.329, 4.394] | 30/0 |
| median/cold64 complete frame | 0.003 [0.003, 0.003] | 2.633 [2.564, 2.704] | 2.962 [2.398, 3.420] | 10.293 [10.145, 10.602] | 15.990 [15.414, 17.035] | 22/8 |
| median/cold32 complete frame | 0.003 [0.003, 0.003] | 2.625 [2.561, 2.678] | 0.079 [0.052, 0.123] | 1.798 [1.709, 1.820] | 4.546 [4.451, 4.628] | 24/6 |
| median/warm complete frame | 0.002 [0.002, 0.003] | 2.581 [2.543, 2.657] | 0.003 [0.003, 0.004] | 1.678 [1.646, 1.713] | 4.279 [4.254, 4.413] | 26/4 |
| ridge/cold64 complete frame | 0.004 [0.004, 0.004] | 2.686 [2.661, 2.703] | 2.876 [2.624, 3.769] | 10.125 [10.083, 10.193] | 16.568 [15.593, 17.267] | 29/1 |
| ridge/cold32 complete frame | 0.003 [0.003, 0.003] | 2.650 [2.630, 2.678] | 0.043 [0.023, 0.077] | 1.810 [1.803, 1.818] | 4.595 [4.534, 4.841] | 30/0 |
| ridge/warm complete frame | 0.003 [0.003, 0.003] | 2.607 [2.595, 2.632] | 0.003 [0.003, 0.003] | 1.732 [1.725, 1.739] | 4.355 [4.324, 4.441] | 29/1 |
| gabor/cold64 complete frame | 0.005 [0.004, 0.005] | 2.728 [2.691, 2.758] | 3.716 [3.551, 5.596] | 10.459 [10.383, 10.502] | 17.548 [17.264, 18.977] | 15/0 |
| gabor/cold32 complete frame | 0.004 [0.003, 0.004] | 2.764 [2.718, 2.819] | 0.051 [0.029, 0.081] | 1.858 [1.842, 1.881] | 4.756 [4.619, 4.995] | 15/0 |
| gabor/warm complete frame | 0.004 [0.003, 0.004] | 2.724 [2.717, 2.983] | 0.004 [0.004, 0.004] | 1.834 [1.786, 1.846] | 4.565 [4.546, 4.840] | 15/0 |
| localNormalization/cold64 complete frame | 1.845 [1.833, 1.862] | 3.250 [3.191, 3.533] | 4.885 [4.698, 5.153] | 10.419 [10.328, 11.074] | 20.829 [20.394, 21.233] | 30/0 |
| localNormalization/cold32 complete frame | 1.745 [1.733, 1.777] | 3.175 [3.126, 3.340] | 2.444 [2.271, 2.712] | 2.453 [2.431, 2.473] | 9.997 [9.811, 10.171] | 29/1 |
| localNormalization/warm complete frame | 1.592 [1.573, 1.605] | 3.250 [3.133, 3.394] | 1.563 [1.548, 1.584] | 2.495 [2.476, 2.530] | 8.979 [8.897, 9.061] | 30/0 |
| pathOpening/cold64 complete frame | 1.542 [1.523, 1.581] | 3.292 [3.219, 3.348] | 3.091 [2.732, 4.091] | 10.491 [10.392, 10.677] | 18.779 [18.006, 19.893] | 28/2 |
| pathOpening/cold32 complete frame | 1.487 [1.450, 1.497] | 3.097 [3.085, 3.153] | 0.037 [0.027, 0.066] | 1.876 [1.859, 1.900] | 6.521 [6.457, 6.748] | 29/1 |
| pathOpening/warm complete frame | 1.407 [1.387, 1.457] | 3.103 [3.085, 3.181] | 0.003 [0.003, 0.004] | 1.827 [1.821, 1.849] | 6.334 [6.305, 6.500] | 28/2 |

Explicit 5 ns/px view-only admission: **PASS**. It covers cold32-view and warm-view for the five named scalar features; it never replaces full-frame Engine/worker budgets.

Phase gates:

- pass: gaussian/cold32-view: view-only overhead
- pass: gaussian/warm-view: view-only overhead
- pass: gradient/cold32-view: view-only overhead
- pass: gradient/warm-view: view-only overhead
- pass: median/cold32-view: view-only overhead
- pass: median/warm-view: view-only overhead
- pass: ridge/cold32-view: view-only overhead
- pass: ridge/warm-view: view-only overhead
- pass: gabor/cold32-view: view-only overhead
- pass: gabor/warm-view: view-only overhead

### Engine phase instruction attribution

A separate no-inline diagnostic build preserves named boundaries. One 64² completed frame is collected. Source excludes nested preparation; residual includes planning/setup/kernel. These costs are not primary wall-time measurements.

| Feature / mode | Source Ir | Prepare Ir | Cache Ir | Sink Ir | Residual Ir |
|---|---:|---:|---:|---:|---:|
| gaussian/cold64 | 193 | 129974 | 514086 | 458792 | 379289 |
| gaussian/cold32 | 193 | 129974 | 1773 | 47806 | 644232 |
| gaussian/warm | 193 | 129974 | 987 | 47806 | 167175 |
| gaussian/cold64-view | 193 | 129974 | 514086 | 26 | 379301 |
| gaussian/cold32-view | 193 | 129974 | 1773 | 11 | 644256 |
| gaussian/warm-view | 193 | 129974 | 987 | 11 | 167199 |
| gradient/cold64 | 193 | 129974 | 514086 | 458792 | 1310034 |
| gradient/cold32 | 193 | 129974 | 1773 | 47806 | 1597398 |
| gradient/warm | 193 | 129974 | 987 | 47806 | 1120165 |
| gradient/cold64-view | 193 | 129974 | 514086 | 26 | 1310046 |
| gradient/cold32-view | 193 | 129974 | 1773 | 11 | 1597422 |
| gradient/warm-view | 193 | 129974 | 987 | 11 | 1120189 |
| median/cold64 | 193 | 129974 | 514086 | 458792 | 404315 |
| median/cold32 | 193 | 129974 | 1773 | 47806 | 669830 |
| median/warm | 193 | 129974 | 987 | 47806 | 192797 |
| median/cold64-view | 193 | 129974 | 514086 | 26 | 404327 |
| median/cold32-view | 193 | 129974 | 1773 | 11 | 669854 |
| median/warm-view | 193 | 129974 | 987 | 11 | 192797 |
| ridge/cold64 | 193 | 138998 | 514086 | 458792 | 2392477 |
| ridge/cold32 | 193 | 138998 | 1773 | 47806 | 2668250 |
| ridge/warm | 193 | 138998 | 987 | 47806 | 2174202 |
| ridge/cold64-view | 193 | 138998 | 514086 | 26 | 2392477 |
| ridge/cold32-view | 193 | 138998 | 1773 | 11 | 2668250 |
| ridge/warm-view | 193 | 138998 | 987 | 11 | 2174178 |
| gabor/cold64 | 193 | 142478 | 514086 | 458792 | 18150311 |
| gabor/cold32 | 193 | 142478 | 1773 | 47806 | 18293886 |
| gabor/warm | 193 | 142478 | 987 | 47806 | 17791628 |
| gabor/cold64-view | 193 | 142478 | 514086 | 26 | 18150311 |
| gabor/cold32-view | 193 | 142478 | 1773 | 11 | 18293886 |
| gabor/warm-view | 193 | 142478 | 987 | 11 | 17791604 |

The spare-initialization change reduces the same 64² cold-planar cache section from 63,487 to 1,773 instructions. Owned capacities, masks and transactional publication are unchanged; poisoned spare tests cover all three planes and all masks.

## Existing fixed full-frame admissions

Combined Engine/phase/Canny gate: **PASS**. Existing thresholds are unchanged.

Effect labels in this table describe added Engine work relative to the prepared worker/reference. Source-change effects use the earlier before/after table.

| Feature / mode | Engine ns/px ± MAD | Worker/reference ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect | Budget |
|---|---:|---:|---:|---:|---:|---|
| gaussian/cold64 | 21.543 ± 0.792 | 8.477 ± 0.106 | 2.506 [2.442, 2.611] | 22/8 | regression | pass |
| gaussian/cold32 | 9.406 ± 0.294 | 8.463 ± 0.068 | 1.114 [1.084, 1.124] | 29/1 | regression | pass |
| gaussian/warm | 7.955 ± 0.124 | 8.516 ± 0.132 | 0.930 [0.915, 0.948] | 27/3 | inconclusive | pass |
| gradient/cold64 | 57.006 ± 1.551 | 46.007 ± 0.481 | 1.238 [1.211, 1.258] | 30/0 | regression | pass |
| gradient/cold32 | 47.062 ± 0.903 | 46.213 ± 0.532 | 1.030 [0.994, 1.044] | 27/3 | inconclusive | pass |
| gradient/warm | 45.590 ± 0.503 | 45.894 ± 0.538 | 0.987 [0.982, 0.992] | 30/0 | inconclusive | pass |
| median/cold64 | 20.859 ± 0.630 | 5.968 ± 0.091 | 3.446 [3.374, 3.553] | 30/0 | regression | pass |
| median/cold32 | 8.268 ± 0.404 | 5.940 ± 0.076 | 1.389 [1.327, 1.414] | 28/2 | regression | pass |
| median/warm | 6.683 ± 0.092 | 5.977 ± 0.108 | 1.109 [1.091, 1.131] | 28/2 | regression | pass |
| ridge/cold64 | 80.038 ± 2.255 | 58.523 ± 0.618 | 1.366 [1.355, 1.407] | 29/1 | regression | pass |
| ridge/cold32 | 59.470 ± 1.456 | 58.178 ± 0.771 | 1.022 [1.008, 1.025] | 29/1 | inconclusive | pass |
| ridge/warm | 57.903 ± 0.773 | 58.520 ± 0.825 | 0.988 [0.985, 0.998] | 29/1 | inconclusive | pass |
| gabor/cold64 | 288.422 ± 1.418 | 330.823 ± 3.517 | 0.869 [0.856, 0.882] | 15/0 | improvement | pass |
| gabor/cold32 | 334.322 ± 2.121 | 330.489 ± 3.052 | 1.016 [1.000, 1.023] | 15/0 | inconclusive | pass |
| gabor/warm | 329.786 ± 1.198 | 330.777 ± 2.384 | 0.997 [0.993, 1.006] | 15/0 | inconclusive | pass |
| localNormalization/cold64 | 62.727 ± 2.156 | 36.653 ± 0.413 | 1.716 [1.693, 1.730] | 30/0 | regression | pass |
| localNormalization/cold32 | 57.982 ± 1.573 | 36.416 ± 0.300 | 1.580 [1.565, 1.633] | 28/2 | regression | pass |
| localNormalization/warm | 55.283 ± 0.923 | 37.196 ± 0.665 | 1.486 [1.477, 1.521] | 30/0 | regression | pass |
| pathOpening/cold64 | 44.236 ± 1.268 | 27.038 ± 0.243 | 1.622 [1.601, 1.672] | 30/0 | regression | pass |
| pathOpening/cold32 | 33.014 ± 0.993 | 27.116 ± 0.315 | 1.220 [1.188, 1.232] | 29/1 | regression | pass |
| pathOpening/warm | 31.642 ± 0.360 | 26.935 ± 0.252 | 1.168 [1.165, 1.179] | 30/0 | regression | pass |
| canny/canny-d | 31.978 ± 0.365 | 31.881 ± 0.499 | 1.005 [0.984, 1.042] | 15/0 | inconclusive | pass |
| canny:native/canny-d | 31.914 ± 0.231 | 29.292 ± 0.143 | 1.088 [1.076, 1.113] | 15/0 | inconclusive | pass |

Gabor uses the same ordered Float64 tap arithmetic but distinct output adapters. The AoS path stores contiguous Float64 Value records and converts once in the full-frame consumer; planar/worker paths emit separate Float32 channels and masks on improving bank winners, including conversion and underflow-orientation handling. The prepared worker also validates/packs support and copies the frame; it is not a bare bank-only clock. The matched Engine/worker rows above qualify these concrete paths, rather than assuming prepared must always beat every output specialization. The separate 64² worker companion records 18,030,060 instructions and the same complete hash as the Engine. This identifies different emission/validation work; it does not establish a precise microarchitectural cause for the remaining timing difference.

Remaining full-frame gates:

- None.

## Correctness and reproducibility

All 12 supported compiler/configuration combinations pass, as do DMD/LDC scoped API probes (16 negative contracts), DDOX and independent DMD plus LDC portable/v3/native references. Exact original-algorithm twins cover all Hessian formulas/polarities, fractional/max scales, signed zero, scientific offsets and narrow/odd layouts. Shape-aware independent ROI checks and legacy reservation remain covered. Borrow tests include dense/gapped, negative-row, nonfinite/wide/masked fallback and malformed-callback rollback, with committed cache preservation.
The initial canary retained first-touch write misses after benchmark call-layout changes. A same-signature, same-depth preheat after telemetry/JSON makes the prepared cache scope repeatable; initial failures remain in the archive. No ceiling or production arithmetic is changed. The final six-kernel instruction/cache canary is **PASS** under its unchanged ceilings. Actual warm Engine and isolated-worker resource receipts, complete hashes, allocation counts and all raw/rejected cycles are retained in the checksummed evidence archive. Synthetic fixtures do not establish reviewed multi-tool consumer acceptance.
These analysis-throughput results do not extend the separate resident display-only 60-fps qualification.
raster-d 0.5.5 contiguousRowSpan has an independently reproduced element/byte-stride defect ([raster-d #290](https://github.com/alex-1974/raster-d/issues/290)). The new packer uses correct affine row.load access; the upstream report does not block this implementation.


The [artifact manifest](engine-gaussian-artifacts-2026-11-24.json) records the verified archive checksum, source checkpoint, measured commit and 783 individually verified files. The archive includes a source bundle and all historical/rejected diagnostic rows; only the final-qualification-v2 directory supplies the final admissions.
