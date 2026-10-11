#!/usr/bin/env python3
"""Summarize paired M3.2.7 ROI control-plane benchmarks.

No external Python packages. Report observed wall-clock distributions,
not unqualified speedup or production performance claims.
"""
import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

MODES = ("raster_only", "revalidated_image", "verified_immutable_image")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True, type=Path)
    ap.add_argument("--summary", required=True, type=Path)
    ap.add_argument("--json", required=True, type=Path)
    args = ap.parse_args()

    groups = defaultdict(list)
    cycles = defaultdict(dict)
    seen = set()

    with args.raw.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {
            "tag", "run", "channels", "round", "slot",
            "mode", "iterations", "elapsed_ns", "checksum",
        }
        if set(reader.fieldnames or []) != required:
            raise ValueError("unexpected raw CSV schema")

        for row in reader:
            if row["tag"] != "roi_xps" or row["mode"] not in MODES:
                raise ValueError("unrecognized row: " + str(row))
            run, n, rnd, slot, loops, ns, checksum = (
                int(row[k]) for k in
                ("run", "channels", "round", "slot",
                 "iterations", "elapsed_ns", "checksum")
            )
            if loops <= 0 or ns <= 0 or checksum <= 0:
                raise ValueError("nonpositive timing/iteration/checksum")
            key = (run, n, rnd, row["mode"])
            if key in seen:
                raise ValueError("duplicate measurement: " + str(key))
            seen.add(key)
            pair = (run, n, rnd)
            cycles[pair][row["mode"]] = (loops, checksum, ns, slot)
            groups[(n, row["mode"])].append({
                "run": run, "round": rnd, "elapsed_ns": ns,
                "ns_per_call": ns / loops,
            })

    if not cycles:
        raise ValueError("no benchmark rows")

    for key, measured in cycles.items():
        if set(measured) != set(MODES):
            raise ValueError("missing mode in cycle " + str(key))
        if len({p[0] for p in measured.values()}) != 1:
            raise ValueError("different iterations within paired cycle")
        if len({p[1] for p in measured.values()}) != 1:
            raise ValueError("different checksums within paired cycle")
        if sorted(p[3] for p in measured.values()) != [0, 1, 2]:
            raise ValueError("unbalanced/duplicate slots " + str(key))

    summaries = []
    channels = sorted(set(k[0] for k in groups))
    for n in channels:
        for mode in MODES:
            data = groups[(n, mode)]
            if not data:
                raise ValueError("missing measurements")
            values = sorted(v["ns_per_call"] for v in data)
            median = statistics.median(values)
            p10 = values[int((len(values) - 1) * 0.1)]
            p90 = values[int((len(values) - 1) * 0.9)]
            summaries.append({
                "channels": n,
                "mode": mode,
                "samples": len(values),
                "median_ns_per_call": round(median, 3),
                "p10_ns_per_call": round(p10, 3),
                "p90_ns_per_call": round(p90, 3),
                "min_ns_per_call": round(values[0], 3),
                "max_ns_per_call": round(values[-1], 3),
                "mad_ns_per_call": round(
                    statistics.median(abs(v - median) for v in values), 3
                ),
            })

    paired = []
    for n in channels:
        relevant = [
            v for (run, k, rnd), v in cycles.items() if k == n
        ]
        ratios = [
            c["revalidated_image"][2] /
            c["verified_immutable_image"][2]
            for c in relevant
        ]
        paired.append({
            "channels": n,
            "pairs": len(ratios),
            "exploratory_paired_ratio_median": round(
                statistics.median(ratios), 3
            ),
        })

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    with args.summary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)
    args.json.write_text(
        json.dumps({
            "schema": "imagery-d-m3.2.7-roi-xps-v1",
            "disclaimer": "Exploratory control-plane microbenchmark. "
                          "Codegen and XPS environment must be reviewed "
                          "before interpreting ratios.",
            "paired_cycle_count": len(cycles),
            "summary": summaries,
            "paired": paired,
        }, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Validated paired cycles:", len(cycles))
    for row in summaries:
        print(
            f"{row['channels']:4} {row['mode']:<26} "
            f"median {row['median_ns_per_call']:>10} ns/call "
            f"(p10 {row['p10_ns_per_call']}, "
            f"p90 {row['p90_ns_per_call']})"
        )


if __name__ == "__main__":
    main()
