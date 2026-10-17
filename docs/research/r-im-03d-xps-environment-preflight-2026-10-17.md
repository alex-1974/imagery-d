# R-IM-03d — Passive native XPS benchmark-environment preflight

**Date:** 2026-10-17. **Classification:** research measurement hygiene, **not production code**, a compiler-performance result, or a machine health diagnosis. **Source basis:** user-provided XPS `sensors`, thermal sysfs counters, `top`, `free -h`, and `vmstat` from Oct 17; the native R-IM-03d [8-process case-order results](r-im-03d-xps-order-2026-10-17-results.md). Public `imagery-d` and `raster-d` contracts remain unchanged.

## Why this observation is necessary

The original R-IM-03d native XPS experiment produced strongly variable late-case times, while the same u16 interleaved masked Levels operation executed near the baseline in six of seven occurrences. The CPU Package sensor reached **100 °C** during some later processes, but the original logs included only **before/after** temperature/frequency snapshots and did **not** show an exact synchronized throttle-event stream for each slow method invocation.

Subsequent **out-of-band user observations** revealed:
- CPU0 Linux package `thermal_throttle/package_throttle_count` **96684** at one observation, then **97161** at a later one (**+477 cumulative events** between unknown workloads). Core0 **13422→13441**, i.e. +19 events across that separate interval. These values must **not** be attributed to any particular R-IM-03d method.
- During an explicitly observed **60-second low-load window** (21:50:22–21:51:22 CEST): CPU Package **79→67 °C**, package throttle **97161→97161 (delta 0)**, core0 throttle **13441→13441 (delta 0)**. Thus no transitions were reported in that period. It does **not** exclude throttling under load.
- At **21:57 CEST**, the **second** `top -b -n 2` sample reported **87.4% aggregate idle CPU**, but Firefox content **PID 14348 used 99.5% of one logical CPU** and approximately **3.5 GiB RES**. Another Firefox content process PID 14679 used 23.4% of one logical CPU / about 1.6 GiB RES. Firefox main process PID 13345 used 15.9%, GNOME Shell 9.9%. Firefox tabs/addons were **not identified**. A `top` process %CPU is distinct from machine-wide CPU %. A raw `ps %CPU` is a process-lifetime average and cannot substitute for this sampling.
- `free`/`top` showed ~**6,070 MiB available RAM** while **3,182.7 MiB swap remained allocated**. The subsequent five `vmstat -w 1 6` interval rows showed `si = 24,0,0,20,0` KiB/s, `so = 0,0,0,0,0` KiB/s and **0% I/O wait**; the used-swap number alone therefore was **not evidence of active thrashing**.

**Causal boundary:** the Firefox and low-load terminal observations are **later** than the previous benchmark. They establish a current per-core background-load risk and historical thermal-throttle events, **not** the exact cause of any earlier R-IM-03d timing outlier.

## Research-only observer

File: [`tools/research/inspect_r_im_03d_xps_environment.sh`](../../tools/research/inspect_r_im_03d_xps_environment.sh)

Usage from a pinned **isolated** R-IM-03d checkout (no DUB build or image workload):

```bash
bash tools/research/inspect_r_im_03d_xps_environment.sh 5
```

- Requires Linux with readable `/proc`, `top` and `vmstat`; `sensors`, `free` and `swapon` are optional where supported.
- Optional **1–15 second** interval (default 5 s); prints a stable `RIM03D_ENV_*` schema, timestamps, CPU0 package/core thermal-throttle counters, available CPU0 scaling clock, optional sensors output and a valid **second** `top` process snapshot. Reads all of top's stream rather than using `tail` or terminating a producer early (which could confuse `pipefail`).
- Captures RAM/swap status and `vmstat -w 1 N` interval observations. **Skip the first since-boot row**, which is not an instantaneous swapping measurement.
- **No root/sudo required; no process kill, Firefox tabs closed, cache purge, swapoff, fan setting, governor change, affinity pin, throttling reset, automatic CPU stress, benchmark start, or sibling repo mutation.** Output is stdout unless the caller deliberately redirects it.
- Does not assign a hard-coded safe/unsafe threshold based on temperature, per-process CPU, available memory or an already occupied swap file. Counter differences must be interpreted with interval exposure and the machine's thermal state. It also cannot associate Firefox PIDs with tabs: inspect `about:processes` if desired.
- A **hosted CI smoke** (not native performance evidence) verifies Bash syntax, rejects bad duration inputs and asserts schema markers; the existing independent Level consumer and mathematical benchmark's code paths remain unchanged.

## Interpretation gate for subsequent optimized D versus Clang C++ research

1. Before repeating heavy native workloads, check laptop cooling/airflow and background Firefox tabs: isolate the largest active content process using `about:processes`; save browser work before optionally unloading idle/unneeded tabs. Avoid forcibly killing processes.
2. Obtain one or more **short passive** observer reports on an otherwise quiet machine; record sample time, temperature and throttle **deltas**, second-sample per-process CPU utilization, actual `vmstat si/so` and available memory, plus governor/AC power conditions where available.
3. Do **not** assume that an idle-safe preflight guarantees a load-stable CPU or that no new throttle transitions will occur during image processing; serious benchmark qualification needs **time-correlated during-test telemetry** and independent repeat sessions after cooling concerns are reviewed.
4. Do not compare pathological hot runs to optimized C++ and claim a language or algorithmic gap. Compare equal source/destination layouts, validation work, rounding, masking, output ownership and bounds-check configuration in consumer-representative release builds.
5. Preserve the previous R-IM-03c and R-IM-03d negative research and exact input logs. This preflight does not update accepted ADRs, `raster-d`, public imagery API, or the statistical basis of the earlier results.

**Open follow-up:** [Issue #92](https://github.com/alex-1974/imagery-d/issues/92), [Draft PR #91](https://github.com/alex-1974/imagery-d/pull/91). Read-only environmental diagnosis does not close the native thermal-mechanism gate.
