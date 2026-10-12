#!/usr/bin/env python3
"""Independent strict M3.2.16 bounded GC intervention evidence validator.

Does not infer collection causality or treat an out-of-timer precollection
as eliminated latency. The three conditions execute as isolated processes.
"""
import argparse
import csv
import json
import math
import re
import statistics
from collections import defaultdict
from pathlib import Path

MODES = ("normal", "precollect", "deferred")
FIELDS = (
    "policy", "round", "channels", "roi_side", "layout", "reuse",
    "setup_ns", "map_ns", "total_ns", "checksum", "expected",
    "allocated_bytes", "in_batch_collections", "in_batch_pause_ns",
    "minor_faults", "major_faults", "collect_before_ns",
    "collect_before_cycles", "collect_before_pause_ns",
    "heap_used_before", "heap_free_before", "heap_used_after",
    "heap_free_after", "after_enable_collections", "after_enable_pause_ns",
)
INT_FIELDS = tuple(k for k in FIELDS if k not in ("policy", "layout", "checksum", "expected"))
PARAMS = re.compile(
    r"^repeats=(\d+) rounds=(\d+) warmups=(\d+) smoke=(0|1) side=(\d+) reuse=(\d+)$",
    re.MULTILINE,
)
LOGNAME = re.compile(r"^run-(0|[1-9][0-9]*)-(normal|precollect|deferred)\.log$")


def independent_expected(absolute_round, count):
    """Physical-value first component with changing binding and ROI origin."""
    choice = (absolute_round * 5 + count) % 8
    permutation = (absolute_round + count) % 3
    channel = (255, 254, 253)[permutation]
    xs = (0, 3, 13, 29)
    ys = (0, 7, 17, 23)
    total = 0.0
    for i in range(count):
        idx = (i + absolute_round) % 4
        x, y = xs[idx], ys[idx]
        if (x + y) % 11 != 0:
            total += (channel * 16 + y * 2 + x) * (
                0.5 + choice * 0.0625
            ) - 4 - choice
    return total


def config(directory):
    text = (directory / "environment.txt").read_text(encoding="utf-8")
    found = PARAMS.findall(text)
    if len(found) != 1:
        raise ValueError("Missing or ambiguous intervention parameters")
    repeats, rounds, warmups, smoke, side, count = map(int, found[0])
    if (repeats < 1 or rounds <= 0 or warmups < 0 or warmups > rounds
            or side not in (8, 32) or count not in (1, 4, 16)
            or (smoke and rounds > 8)):
        raise ValueError("Invalid intervention parameters")
    if "schema=imagery-d-m3.2.16-gc-intervention-v1" not in text:
        raise ValueError("Invalid intervention schema")
    return repeats, rounds, warmups, bool(smoke), side, count


def qualify(directory):
    repeats, rounds, warmups, smoke, side, count = config(directory)
    filenames = {}
    for path in directory.glob("run-*.log"):
        m = LOGNAME.fullmatch(path.name)
        if not m:
            raise ValueError(f"Unexpected log path: {path.name}")
        key = (int(m[1]), m[2])
        if key in filenames:
            raise ValueError("Duplicate process/mode log")
        filenames[key] = path
    expected_logs = {(i, mode) for i in range(repeats) for mode in MODES}
    if set(filenames) != expected_logs:
        raise ValueError(f"Missing/extra process modes: {expected_logs - set(filenames)}")

    all_rows = []
    for (run, mode), path in sorted(filenames.items()):
        raw = path.read_text(encoding="utf-8")
        if "M3.2.16 PASS: calibrated GC counterfactual pixel oracle" not in raw:
            raise ValueError(f"Missing D oracle pass marker: {path.name}")
        header_seen = False
        rows = []
        for line in csv.reader(raw.splitlines()):
            if not line:
                continue
            if line[0] == "gc_intervention_schema":
                if header_seen or line[1:] != list(FIELDS):
                    raise ValueError("Invalid/duplicate GC intervention header")
                header_seen = True
                continue
            if line[0] != "gc_intervention":
                continue
            if len(line) != len(FIELDS) + 1:
                raise ValueError("Invalid GC intervention row width")
            row = dict(zip(FIELDS, line[1:]))
            try:
                for field in INT_FIELDS:
                    row[field] = int(row[field])
                row["checksum"] = float(row["checksum"])
                row["expected"] = float(row["expected"])
            except (ValueError, OverflowError) as e:
                raise ValueError("Non-numeric GC intervention row") from e
            if (row["policy"] != mode or row["round"] != len(rows)
                    or row["channels"] != 256 or row["roi_side"] != side
                    or row["layout"] != "planar" or row["reuse"] != count):
                raise ValueError("Wrong mode, round order or semantic workload")
            durations = (row["setup_ns"], row["map_ns"], row["total_ns"])
            if durations[0] < 0 or durations[1] <= 0 or durations[2] <= 0:
                raise ValueError("Invalid measured duration")
            counters = (
                "allocated_bytes", "in_batch_collections",
                "in_batch_pause_ns", "minor_faults", "major_faults",
                "collect_before_ns", "collect_before_cycles",
                "collect_before_pause_ns", "heap_used_before",
                "heap_free_before", "heap_used_after", "heap_free_after",
                "after_enable_collections", "after_enable_pause_ns"
            )
            if any(row[key] < 0 for key in counters):
                raise ValueError("Negative GC, heap or fault counter")
            if (mode != "precollect"
                    and any(row[k] != 0 for k in ("collect_before_ns",
                         "collect_before_cycles", "collect_before_pause_ns"))):
                raise ValueError("Forbidden external precollection in control mode")
            if (mode != "deferred"
                    and any(row[k] != 0 for k in ("after_enable_collections",
                         "after_enable_pause_ns"))):
                raise ValueError("Unexpected enable-time effects outside deferred mode")
            oracle = independent_expected(row["round"] + warmups, count)
            if (not all(math.isfinite(row[k]) for k in ("checksum", "expected"))
                    or not math.isclose(row["checksum"], oracle, rel_tol=1e-5,
                                        abs_tol=1e-4)
                    or not math.isclose(row["expected"], oracle, rel_tol=1e-5,
                                        abs_tol=1e-4)):
                raise ValueError("Independent physical-pixel oracle mismatch")
            row["run"] = run
            rows.append(row)
            all_rows.append(row)
        if not header_seen:
            raise ValueError("Missing intervention header")
        if len(rows) != rounds:
            raise ValueError("Incomplete per-process/mode measurement matrix")

    groups = defaultdict(list)
    for row in all_rows:
        groups[(row["policy"], row["run"])].append(row)
    process_results = []
    for (mode, run), rows in sorted(groups.items()):
        times = [row["setup_ns"] for row in rows]
        process_results.append({
            "policy": mode, "run": run, "samples": len(rows),
            "median_setup_ns": statistics.median(times),
            "max_setup_ns": max(times),
            "setup_over_50us": sum(v > 50_000 for v in times),
            "in_batch_gc_collections": sum(v["in_batch_collections"] for v in rows),
            "in_batch_gc_pause_ns": sum(v["in_batch_pause_ns"] for v in rows),
            "external_gc_collections": sum(v["collect_before_cycles"] for v in rows),
            "external_gc_pause_ns": sum(v["collect_before_pause_ns"] for v in rows),
            "external_collection_wall_ns": sum(v["collect_before_ns"] for v in rows),
            "after_enable_gc_collections": sum(
                v["after_enable_collections"] for v in rows),
            "max_heap_used_reported": max(v["heap_used_after"] for v in rows),
            "min_heap_free_reported": min(v["heap_free_after"] for v in rows),
            "allocated_bytes": sum(v["allocated_bytes"] for v in rows),
            "minor_faults": sum(v["minor_faults"] for v in rows),
            "major_faults": sum(v["major_faults"] for v in rows)
        })
    tails = [
        {k: row[k] for k in ("run", "policy", "round", "setup_ns",
                             "in_batch_collections", "in_batch_pause_ns",
                             "minor_faults", "major_faults",
                             "collect_before_cycles")}
        for row in all_rows if row["setup_ns"] > 50_000
    ]
    return all_rows, process_results, {
        "schema": "imagery-d-m3.2.16-gc-intervention-v1",
        "repeats": repeats, "rounds": rounds, "warmups": warmups,
        "roi_side": side, "reuse": count,
        "rows": len(all_rows), "complete": True,
        "independent_oracle": "PASS", "processes": process_results,
        "setup_tails_over_50us": tails,
        "caveat": (
            "Interventions run in separate processes with different heap states. "
            "GC.disable does not prohibit allocation or emergency collections. "
            "Precollect cost is OUTSIDE timed setup and must be counted before "
            "any end-to-end comparison. No-GC tail can arise from page faults "
            "or scheduling. Heap size statistics may update only at collection."
        )
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    directory = p.parse_args().directory
    rows, processes, summary = qualify(directory)
    with (directory / "gc-intervention-raw.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (directory / "gc-intervention-processes.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, list(processes[0]))
        writer.writeheader()
        writer.writerows(processes)
    (directory / "gc-intervention-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(f"PASS: {summary['rows']} calibrated measured batches "
          f"across {repeats * len(MODES)} distinct processes")
    print("Caution: outside-timer collections and heap-state differences "
          "preclude a direct end-to-end policy winner.")


if __name__ == "__main__":
    main()
