#!/usr/bin/env python3
"""Validate actual Linux process-memory stage evidence for imagery-d M3.

The VM/allocator observations are process-level and not additively
composable with GC or known pixel payloads. Never invent an exact
per-raster native memory bound or a transient producer peak.
"""
import csv
import io
import sys
from pathlib import Path

HEADER = ("experiment,side,phase,active_generations,requested_live_"
          "payload_bytes,illustrative_charge_bytes,thread_gc_cumulative_"
          "bytes,glibc_malloc_used_bytes,glibc_mmap_bytes,glibc_free_bytes,"
          "vmrss_kib,vmhwm_kib")
PHASES = (
    "fixtures", "accounting", "a_live", "a_evicted",
    "ab_live", "abc_live", "cache_exited",
    "a_closed", "b_closed", "c_closed",
)
ACTIVE = (0, 0, 1, 1, 2, 3, 3, 2, 1, 0)


def validate(source: str) -> dict:
    lines = source.splitlines()
    if lines.count(HEADER) != 1:
        raise ValueError("expected exactly one memory CSV header")
    passes = [line for line in lines
              if line.startswith("M3 GENERATION MEMORY PASS:")]
    if len(passes) != 1:
        raise ValueError("missing or repeated success trailer")
    records = [line for line in lines
               if line.startswith("m3_generation_memory,")]
    if len(records) != len(PHASES):
        raise ValueError("missing or duplicated phase rows")
    reader = csv.DictReader(io.StringIO(HEADER + "\n" +
                                       "\n".join(records)))
    rows = list(reader)
    if len(rows) != len(PHASES) or any(None in row or
                                      None in row.values() for row in rows):
        raise ValueError("malformed phase CSV")
    numeric = tuple(name for name in rows[0]
                    if name not in ("experiment", "phase"))
    try:
        for row in rows:
            for field in numeric:
                row[field] = int(row[field])
    except (TypeError, ValueError) as exc:
        raise ValueError("noninteger phase metric") from exc
    side = rows[0]["side"]
    if side not in (16, 64, 256, 512):
        raise ValueError("unknown ROI side")
    payload = 4 * side * side
    for i, row in enumerate(rows):
        if row["experiment"] != "m3_generation_memory" or (
            row["side"] != side or row["phase"] != PHASES[i] or
            row["active_generations"] != ACTIVE[i] or
            row["requested_live_payload_bytes"] != ACTIVE[i] * payload or
            row["illustrative_charge_bytes"] != ACTIVE[i] * (payload + 64)
        ):
            raise ValueError("impossible phase or payload/credit trace")
        if any(row[k] < 0 for k in numeric):
            raise ValueError("negative process memory metric")
        if row["vmhwm_kib"] < row["vmrss_kib"]:
            raise ValueError("HWM below current resident bytes")
        # Linux /proc VmHWM is reported as a high-water mark, yet an
        # actual LDC 1.43 Ubuntu CI trace showed 5104 -> 5040 KiB
        # after a native mmap deallocation. Do NOT erase/rewrite it or
        # reject an otherwise correct ownership/payload trace. Preserve
        # and report every such irregularity as measurement evidence.
        if i and (row["thread_gc_cumulative_bytes"] <
                  rows[i-1]["thread_gc_cumulative_bytes"]):
            raise ValueError(
                f"GC allocation counter decreased at {PHASES[i]}: "
                f"{rows[i-1]['thread_gc_cumulative_bytes']} -> "
                f"{row['thread_gc_cumulative_bytes']} bytes")
    regressions = [
        rows[i-1]["vmhwm_kib"] - rows[i]["vmhwm_kib"]
        for i in range(1, len(rows))
        if rows[i]["vmhwm_kib"] < rows[i-1]["vmhwm_kib"]
    ]
    class_delta = (rows[1]["thread_gc_cumulative_bytes"] -
                   rows[0]["thread_gc_cumulative_bytes"])
    # We require the observation, NOT any invented allocator-byte bound.
    if class_delta <= 0:
        raise ValueError("expected an observed accounting class allocation")
    if f"observed control GC allocation={class_delta}" not in passes[0]:
        raise ValueError("reported control allocation disagrees with trace")
    return {
        "side": side,
        "class_gc_allocated_bytes": class_delta,
        "requested_live_payload_max": 3 * payload,
        "vmrss_baseline_kib": rows[0]["vmrss_kib"],
        "vmrss_3_live_kib": rows[5]["vmrss_kib"],
        "vmrss_final_kib": rows[9]["vmrss_kib"],
        "vmhwm_baseline_kib": rows[0]["vmhwm_kib"],
        "vmhwm_3_live_kib": rows[5]["vmhwm_kib"],
        "vmhwm_final_kib": rows[9]["vmhwm_kib"],
        "vmhwm_decrease_events": len(regressions),
        "largest_vmhwm_decrease_kib": max(regressions, default=0),
        "max_observed_vmhwm_kib": max(r["vmhwm_kib"] for r in rows),
        "malloc_used_baseline_bytes": rows[0]["glibc_malloc_used_bytes"],
        "malloc_used_3_live_bytes": rows[5]["glibc_malloc_used_bytes"],
        "malloc_used_final_bytes": rows[9]["glibc_malloc_used_bytes"],
        "malloc_mapped_baseline_bytes": rows[0]["glibc_mmap_bytes"],
        "malloc_mapped_3_live_bytes": rows[5]["glibc_mmap_bytes"],
        "malloc_mapped_final_bytes": rows[9]["glibc_mmap_bytes"],
    }


def self_test():
    rows = [HEADER]
    side = 16
    for i, phase in enumerate(PHASES):
        n = ACTIVE[i]
        gc = 200 + (256 if i >= 1 else 0)
        rss = 1000 + n * 4
        hwm = 1000 + max(ACTIVE[:i+1]) * 4
        rows.append(
            f"m3_generation_memory,{side},{phase},{n},{n*1024},"
            f"{n*1088},{gc},{20000+n*1024},0,12000,"
            f"{rss},{hwm}"
        )
    rows.append("M3 GENERATION MEMORY PASS: observed control GC allocation=256")
    data = "\n".join(rows) + "\n"
    assert validate(data)["class_gc_allocated_bytes"] == 256
    # Reproduce the actual CI anomaly in a synthetic sample: high-water
    # reported by /proc can be lower after a native mmap release.
    odd = data.replace(
        "a_closed,2,2048,2176,456,22048,0,12000,1008,1012",
        "a_closed,2,2048,2176,456,22048,0,12000,1008,1008"
    )
    result = validate(odd)
    assert result["vmhwm_decrease_events"] == 1
    assert result["largest_vmhwm_decrease_kib"] == 4
    bad = [
        data.replace("c_closed,0,0,0", "c_closed,1,1024,1088"),
        data.replace("a_closed,2,2048,2176", "a_closed,3,3072,3264"),
        data.replace("observed control GC allocation=256",
                     "observed control GC allocation=128"),
        data.replace("M3 GENERATION MEMORY PASS:", "BROKEN PASS:"),
    ]
    for corrupted in bad:
        try:
            validate(corrupted)
        except ValueError:
            continue
        raise AssertionError("accepted incorrect memory evidence")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        print("GENERATION MEMORY VALIDATOR SELF-TEST PASS")
    elif len(sys.argv) == 2:
        try:
            report = validate(Path(sys.argv[1]).read_text())
        except (OSError, ValueError) as exc:
            sys.exit(f"invalid generation-memory evidence: {exc}")
        writer = csv.DictWriter(sys.stdout, fieldnames=tuple(report))
        writer.writeheader()
        writer.writerow(report)
    else:
        sys.exit("Usage: summarize_m3_rgba_generation_memory_xps.py [--self-test|runner.txt]")
