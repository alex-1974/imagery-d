# Engine/window follow-up, 2026-11-23

Refs #212 and #213.

## Admission

Original Engine/phase/Canny collection: **pending**. Window/path: **pass**. Separate steady-preheat aligned Canny: **pass**.
Functional correctness and fixed performance admission are separate. Pending evidence is never PASS.

Engine binary source: `640f44bb3a377041995e2ce9fa2c833b72b8a9d1`. Window binary source: `640f44bb3a377041995e2ce9fa2c833b72b8a9d1`.
Resource/counter/scaling source: `d049ecd21421dd94977c15bc68022d596a7e936a`; the later Hessian/tensor-only change is qualified separately.
Baseline: 5b1b0b95a57c2e31dbed1fedcd5dfdafe8a4909d plus identical benchmark-only overlay; benchmark overlay SHA-256 `a5e529eaaabbd5d02fb78d9ddbe2f6b61cb3f2e6016addce25d06d18d4171fee`.
Host: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz. Engine CPU 4; window CPU 2.

All timed arrays use the retained 1024² deterministic fixture. Engine comparisons use strict Float64 arithmetic and identical final Float32 planes/masks, including complete frame publication. Gaussian32 is a different policy and is excluded. Window probes use actual Float32 input storage and Float64 statistics; frame publication is outside their per-tile kernel clocks.

Effect labels describe the named A/B scopes. Conclusions about source revisions require the corresponding before/after rows; parameter-scaling and Engine/worker ratios primarily describe their different work and publication costs.

ABBA, >=15 accepted complete cycles, medians/MAD and 4,000 whole-cycle bootstrap draws; 10% minimum conclusive effect. Endpoint frequency movement >5%, load >6 or SMT sibling activity >5% reject complete cycles. Zero-tick intervals are unresolved. Governor/power changes are rejected; temperatures and controls remain in raw records. These observations do not establish physical isolation. Sample cells batch 1..100 frames from an untimed pilot targeting >=150 ms. Cold Engine frames use fresh instances; warm batches advance preallocated revision labels and report actual computed tiles and GC bytes.

## Engine and aligned Canny

| Feature / mode | Engine ns/px ± MAD | Prepared/reference ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Budget |
|---|---:|---:|---:|---:|---|---|
| gaussian/cold64 | 47.195 ± 1.189 | 9.299 ± 0.124 | 5.074 pending | 2/43 | inconclusive | pending |
| gaussian/cold32 | 29.709 ± 1.160 | 9.425 ± 0.050 | 3.154 pending | 10/35 | inconclusive | pending |
| gaussian/warm | 27.334 ± 0.315 | 9.466 ± 0.072 | 2.830 [2.804, 2.899] | 15/30 | regression | pass |
| gradient/cold64 | 87.804 ± 1.039 | 53.657 ± 0.933 | 1.651 [1.639, 1.660] | 17/28 | regression | pass |
| gradient/cold32 | 73.419 ± 0.975 | 53.742 ± 1.091 | 1.377 [1.361, 1.387] | 26/19 | regression | pass |
| gradient/warm | 70.568 ± 0.482 | 52.948 ± 0.427 | 1.331 [1.324, 1.338] | 31/14 | regression | pass |
| median/cold64 | 45.586 ± 2.216 | 7.583 ± 0.010 | 6.011 pending | 2/43 | inconclusive | pending |
| median/cold32 | 27.860 ± 0.853 | 7.626 ± 0.083 | 3.609 pending | 9/36 | inconclusive | pending |
| median/warm | 25.728 ± 0.318 | 7.549 ± 0.026 | 3.378 pending | 10/35 | inconclusive | pending |
| ridge/cold64 | 113.090 ± 3.094 | 69.034 ± 0.654 | 1.629 [1.605, 1.658] | 24/21 | regression | pass |
| ridge/cold32 | 89.351 ± 0.768 | 69.479 ± 0.570 | 1.292 [1.283, 1.303] | 28/17 | regression | pass |
| ridge/warm | 87.336 ± 0.748 | 69.075 ± 0.649 | 1.255 [1.251, 1.270] | 19/26 | regression | pass |
| gabor/cold64 | 378.644 ± 3.678 | 331.521 ± 3.348 | 1.148 [1.133, 1.154] | 17/28 | regression | pass |
| gabor/cold32 | 354.499 ± 2.039 | 332.166 ± 2.288 | 1.064 [1.056, 1.072] | 25/20 | inconclusive | pass |
| gabor/warm | 349.380 ± 3.232 | 331.399 ± 1.885 | 1.049 [1.039, 1.068] | 19/26 | inconclusive | pass |
| localNormalization/cold64 | 89.424 ± 1.516 | 49.281 ± 1.259 | 1.842 pending | 7/38 | inconclusive | pending |
| localNormalization/cold32 | 82.575 ± 1.885 | 48.220 ± 0.866 | 1.717 pending | 11/34 | inconclusive | pending |
| localNormalization/warm | 79.306 ± 2.244 | 48.406 ± 0.651 | 1.639 pending | 7/38 | inconclusive | pending |
| pathOpening/cold64 | 65.599 ± 0.958 | 33.596 ± 0.499 | 1.962 pending | 5/40 | inconclusive | pending |
| pathOpening/cold32 | 48.547 ± 0.835 | 33.477 ± 0.510 | 1.451 [1.434, 1.463] | 20/25 | regression | pass |
| pathOpening/warm | 46.662 ± 0.618 | 33.742 ± 0.488 | 1.380 [1.362, 1.386] | 20/25 | regression | pass |
| canny/canny-d | 38.398 ± 0.000 | 35.242 ± 0.000 | 1.090 pending | 1/44 | inconclusive | pending |
| canny:native/canny-d | — ± — | — ± — | — pending | 0/45 | inconclusive | pending |

The matched Gabor rows supersede the historical independently timed prepared/cold discrepancy for this scope. They do not retroactively identify a cause of the historical drift. Canny uses the separately authored equal-work C implementation; both portable and native C builds pass all 120 scalar cases. OpenCV/skimage Canny remain diagnostics.

## Canny with steady batch preheat

Separate binary source: `d049ecd21421dd94977c15bc68022d596a7e936a`; measured CPU 1. Both aligned-reference gates **pass**. The earlier Canny rows above remain retained and pending. This follow-up corrects the benchmark preheat, not the production algorithm: the untimed preheat now computes the same number of frames as the timed >=150 ms batch. A single preheat frame had left frequency changes in the original Canny observations. The frequency/SMT exclusions, fixed 5x target and minimum of 15 accepted complete cycles are unchanged. These are separate sessions and binary hashes, not pooled or selectively replaced cycles.

| Comparator | D ns/px ± MAD | C ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Budget |
|---|---:|---:|---:|---:|---|
| canny | 31.407 ± 0.074 | 31.147 ± 0.101 | 1.007 [1.005, 1.010] | 15/0 | pass |
| canny:native | 32.385 ± 0.208 | 28.957 ± 0.083 | 1.114 [1.108, 1.123] | 15/0 | pass |

## Profiled cold Float64 phases

| Feature | Source | Preparation | Cache | Sink | Sum of these phases |
|---|---:|---:|---:|---:|---:|
| gaussian | 11.046 pending | 5.863 pending | 6.728 pending | 20.116 pending | 43.071 pending |
| gradient | 6.421 pending | 3.977 pending | 7.771 pending | 13.116 pending | 31.485 pending |
| median | 6.436 [6.352, 6.645] | 3.808 [3.569, 4.471] | 6.493 [4.862, 7.120] | 12.098 [11.887, 13.476] | 28.776 [27.220, 31.360] |
| ridge | 6.699 [6.677, 6.764] | 3.847 [3.743, 3.960] | 6.315 [5.721, 6.767] | 12.787 [12.588, 13.104] | 29.871 [29.186, 31.017] |
| gabor | 6.551 [6.536, 6.599] | 3.239 [3.200, 3.284] | 4.070 [3.758, 6.741] | 11.518 [11.373, 11.590] | 26.468 [25.798, 28.647] |
| localNormalization | 6.265 [6.204, 6.292] | 3.175 [3.160, 3.223] | 5.681 [4.633, 7.199] | 10.966 [10.933, 11.041] | 26.819 [25.094, 27.728] |
| pathOpening | 6.431 [6.415, 6.450] | 3.191 [3.173, 3.204] | 4.786 [4.159, 5.146] | 10.883 [10.813, 10.916] | 25.202 [24.879, 25.978] |

Units: ns/pixel with bootstrap intervals. These phase sums are regression envelopes, not a claim that the separate 5 ns/pixel overhead ambition is reached. They are not guaranteed to sum to the outer timer. Existing 5x/4x prepared external targets are unchanged.

## Paths and normalization

| Case | Candidate ns/px ± MAD | Baseline/reference ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Budget |
|---|---:|---:|---:|---:|---|---|
| pathOpening | 25.582 ± 0.116 | 670.187 ± 2.159 | 0.038 [0.038, 0.038] | 15/2 | improvement | pass |
| pathClosing | 24.389 ± 0.068 | 667.197 ± 1.533 | 0.037 [0.037, 0.037] | 15/1 | improvement | pass |
| localNormalization | 36.572 ± 0.291 | 124.470 ± 0.181 | 0.293 [0.292, 0.298] | 15/2 | improvement | pass |
| path-length | 64.836 ± 0.267 | 25.448 ± 0.069 | 2.546 [2.540, 2.557] | 15/0 | regression | pass |
| normalization-r1 | 36.297 ± 0.298 | 15.922 ± 0.277 | 2.268 [2.220, 2.303] | 15/2 | regression | pass |
| normalization-r3 | 36.470 ± 0.220 | 16.617 ± 0.230 | 2.208 [2.177, 2.240] | 15/1 | regression | pass |
| normalization-r7 | 37.114 ± 0.195 | 16.493 ± 0.198 | 2.236 [2.197, 2.281] | 15/1 | regression | pass |
| normalization-r15 | 38.690 ± 0.615 | 16.762 ± 0.161 | 2.375 [2.275, 2.472] | 15/1 | regression | pass |
| normalization-r31 | 42.071 ± 0.875 | 16.869 ± 0.304 | 2.482 [2.423, 2.638] | 15/0 | regression | pass |
| normalization-radius-sensitivity | 41.286 ± 0.237 | 36.286 ± 0.181 | 1.137 [1.131, 1.142] | 15/0 | regression | pass |

## Descriptive raw pairs

The following intervals use all complete cycles, including the rejected frequency/SMT observations. They describe actual recorded load and cannot satisfy the strict admission gate. Raw flags remain unchanged; no timing-based outliers are removed.

| Scope | Raw cycles | Ratio [95% CI] | Observed effect |
|---|---:|---:|---|
| Engine gaussian/cold64 | 45 | 4.888 [4.803, 4.970] | regression |
| Engine gaussian/cold32 | 45 | 3.130 [3.015, 3.163] | regression |
| Engine gaussian/warm | 45 | 2.828 [2.804, 2.859] | regression |
| Engine gradient/cold64 | 45 | 1.649 [1.639, 1.664] | regression |
| Engine gradient/cold32 | 45 | 1.381 [1.377, 1.389] | regression |
| Engine gradient/warm | 45 | 1.329 [1.324, 1.336] | regression |
| Engine median/cold64 | 45 | 5.859 [5.727, 6.013] | regression |
| Engine median/cold32 | 45 | 3.664 [3.590, 3.708] | regression |
| Engine median/warm | 45 | 3.346 [3.327, 3.367] | regression |
| Engine ridge/cold64 | 45 | 1.607 [1.589, 1.630] | regression |
| Engine ridge/cold32 | 45 | 1.296 [1.286, 1.306] | regression |
| Engine ridge/warm | 45 | 1.255 [1.248, 1.262] | regression |
| Engine gabor/cold64 | 45 | 1.149 [1.136, 1.158] | regression |
| Engine gabor/cold32 | 45 | 1.060 [1.055, 1.064] | inconclusive |
| Engine gabor/warm | 45 | 1.056 [1.042, 1.064] | inconclusive |
| Engine localNormalization/cold64 | 45 | 1.826 [1.810, 1.842] | regression |
| Engine localNormalization/cold32 | 45 | 1.699 [1.683, 1.717] | regression |
| Engine localNormalization/warm | 45 | 1.625 [1.604, 1.630] | regression |
| Engine pathOpening/cold64 | 45 | 1.900 [1.851, 1.939] | regression |
| Engine pathOpening/cold32 | 45 | 1.459 [1.447, 1.477] | regression |
| Engine pathOpening/warm | 45 | 1.374 [1.356, 1.381] | regression |
| Engine canny/canny-d | 45 | 1.075 [1.071, 1.079] | inconclusive |
| Engine canny:native/canny-d | 45 | 1.149 [1.143, 1.153] | regression |
| Window pathOpening | 17 | 0.038 [0.038, 0.038] | improvement |
| Window pathClosing | 16 | 0.037 [0.036, 0.037] | improvement |
| Window localNormalization | 17 | 0.293 [0.292, 0.298] | improvement |
| Window path-length | 15 | 2.546 [2.540, 2.557] | regression |
| Window normalization-r1 | 17 | 2.268 [2.220, 2.303] | regression |
| Window normalization-r3 | 16 | 2.209 [2.174, 2.240] | regression |
| Window normalization-r7 | 16 | 2.241 [2.212, 2.264] | regression |
| Window normalization-r15 | 16 | 2.341 [2.268, 2.463] | regression |
| Window normalization-r31 | 15 | 2.482 [2.423, 2.638] | regression |
| Window normalization-radius-sensitivity | 15 | 1.137 [1.131, 1.142] | regression |

Default opening/closing require a paired upper ratio <=0.2 (at least 5x). Length 31 / step 2 versus length 7 / step 1 requires <=3x. Every normalization radius also retains the fixed 78 ns/pixel ceiling (5 x historical 15.6), independent of the fresh OpenCV/NumPy comparison. The radius-sensitivity target is <=2x. Numerical preflight covers masks, minimumValid, scientific units, whole/tiled equality and retained path oracles.

## Resources and deterministic companion

All 98 default Engine computations and all 28 isolated-worker rows have zero warm thread-GC bytes and actual computed tiles. Worker counts are 1, 2, 4 and 12 logical workers, with per-worker ownership. Full output SHA-256 agrees across worker counts. Scaling times are diagnostic, not a claim of linear speedup.

| Feature | Worker arrays | Engine tile arrays | Sum of cache peaks | Caller frame |
|---|---:|---:|---:|---:|
| gaussian | 1582116 | 4293764 | 14926440 | 15728640 |
| gradient | 1582116 | 4293764 | 14926342 | 15728640 |
| median | 1315860 | 4293764 | 14926342 | 15728640 |
| ridge | 1609028 | 4370596 | 14926944 | 15728640 |
| gabor | 1618496 | 4405312 | 14926853 | 15728640 |
| localNormalization | 4271140 | 8015748 | 14926776 | 15728640 |
| pathOpening | 2146196 | 4855972 | 14926517 | 15728640 |

Bytes are owned array payloads, not RSS. The <=8 MiB tile/worker budget excludes caller inputs/complete frames, separate bounded caches, fixed metadata and stack. Local statistics use 18 KiB stack carriers plus 4 KiB constant certificates without extrema (or 16 KiB extrema queues). The exact byte path applies only to complete valid `Float32(code)/255` supports; other samples keep the complete floating/scalar path. Synthetic-fixture throughput does not establish the hit rate of arbitrary consumer scenes.

| Feature | Instructions | D1 simulated data misses | LL simulated data misses |
|---|---:|---:|---:|
| gaussian | 107054 | 1005 | 0 |
| gradient | 346472 | 962 | 0 |
| median | 103505 | 845 | 0 |
| gabor | 4902403 | 1531 | 0 |
| localNormalization | 496374 | 4256 | 165 |
| pathOpening | 666133 | 1348 | 9 |

The manual Callgrind canary uses the fixed 32² collected region and explicit cache model in `instruction-budget-2026-11-23.json`; it is not a physical-counter or wall-time measurement. The reviewed nine path write misses and downward normalization ratchet are documented in that policy. No automatic `--record` calibration repairs failures.

## Non-passing admissions

The two original pending Canny gates are superseded for admission by the separately identified steady-preheat receipt. Their original results and gate records remain in the JSON.

```json
[
  {
    "status": "pending",
    "reason": "gaussian/cold64: strict Engine/prepared ratio",
    "limit": 3
  },
  {
    "status": "pending",
    "reason": "gaussian/cold32: strict Engine/prepared ratio",
    "limit": 3
  },
  {
    "status": "pending",
    "reason": "gaussian: profiled source",
    "limit": 10
  },
  {
    "status": "pending",
    "reason": "gaussian: profiled prepare",
    "limit": 8
  },
  {
    "status": "pending",
    "reason": "gaussian: profiled cache",
    "limit": 12
  },
  {
    "status": "pending",
    "reason": "gaussian: profiled sink",
    "limit": 12
  },
  {
    "status": "pending",
    "reason": "gaussian: profiled overhead",
    "limit": 30
  },
  {
    "status": "pending",
    "reason": "gradient: profiled source",
    "limit": 10
  },
  {
    "status": "pending",
    "reason": "gradient: profiled prepare",
    "limit": 8
  },
  {
    "status": "pending",
    "reason": "gradient: profiled cache",
    "limit": 12
  },
  {
    "status": "pending",
    "reason": "gradient: profiled sink",
    "limit": 12
  },
  {
    "status": "pending",
    "reason": "gradient: profiled overhead",
    "limit": 30
  },
  {
    "status": "pending",
    "reason": "median/cold64: strict Engine/prepared ratio",
    "limit": 5.5
  },
  {
    "status": "pending",
    "reason": "median/cold32: strict Engine/prepared ratio",
    "limit": 5.5
  },
  {
    "status": "pending",
    "reason": "median/warm: strict Engine/prepared ratio",
    "limit": 5.5
  },
  {
    "status": "pending",
    "reason": "median: profiled sink",
    "limit": 12,
    "median": 12.098251825806681,
    "bootstrap_95": [
      11.886636081214283,
      13.475575415492004
    ]
  },
  {
    "status": "pending",
    "reason": "median: profiled overhead",
    "limit": 30,
    "median": 28.775760197255593,
    "bootstrap_95": [
      27.220185755227313,
      31.359616274974577
    ]
  },
  {
    "status": "pending",
    "reason": "ridge: profiled sink",
    "limit": 12,
    "median": 12.78743568637407,
    "bootstrap_95": [
      12.588272959697495,
      13.104409149294703
    ]
  },
  {
    "status": "pending",
    "reason": "ridge: profiled overhead",
    "limit": 30,
    "median": 29.870656371634194,
    "bootstrap_95": [
      29.18632308687623,
      31.016630265502727
    ]
  },
  {
    "status": "pending",
    "reason": "localNormalization/cold64: strict Engine/prepared ratio",
    "limit": 2.5
  },
  {
    "status": "pending",
    "reason": "localNormalization/cold32: strict Engine/prepared ratio",
    "limit": 2.5
  },
  {
    "status": "pending",
    "reason": "localNormalization/warm: strict Engine/prepared ratio",
    "limit": 2.5
  },
  {
    "status": "pending",
    "reason": "pathOpening/cold64: strict Engine/prepared ratio",
    "limit": 2.5
  }
]
```

All binary/oracle/compiler/flag hashes, paired summaries, phase intervals, software counts and exact scaling digests are retained in the adjacent JSON. Complete cycles, including rejected observations, remain in the raw artifact directories. This receipt is not reviewed application acceptance or a general 60-fps claim.
