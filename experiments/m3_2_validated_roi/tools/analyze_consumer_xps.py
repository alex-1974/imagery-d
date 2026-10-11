#!/usr/bin/env python3
"""Summarize paired M3.2.8 image mapping and metadata preparation evidence.

No external dependencies; paired measurements rather than cloud-runner
best-case ratios. Refuses missing/duplicate/mismatched consumer cycles.
"""
import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

MODES = {"revalidated_image", "verified_immutable_image"}
SETUPS = {
    "caller_borrow_validate",
    "already_immutable_validate",
    "snapshot_and_validate",
}


def median(values):
    return statistics.median(values)


def median_abs_deviation(values):
    center = median(values)
    return median([abs(v - center) for v in values])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()

    pairs = defaultdict(dict)
    groups = defaultdict(list)
    setups = defaultdict(list)
    all_rows = []
    n_runs = 0

    for file in sorted(options.logs.glob("run-*.log")):
        n_runs += 1
        run = int(file.stem.split("-")[1])
        for row in csv.reader(file.read_text(encoding="utf-8").splitlines()):
            if not row:
                continue
            if row[0] == "consumer_map":
                if len(row) != 11:
                    raise ValueError(f"invalid map record: {row}")
                _, n, side, layout, mask, round_, slot, mode, iters, ns, checksum = row
                n, side, round_, slot, iters, ns = map(
                    int, (n, side, round_, slot, iters, ns))
                checksum = float(checksum)
                if (mode not in MODES or layout not in ("planar", "interleaved")
                        or mask not in ("masked", "unmasked") or
                        iters < 1 or ns < 1 or slot not in (0, 1)):
                    raise ValueError(f"bad map record: {row}")
                key = (run, n, side, layout, mask, round_)
                if mode in pairs[key]:
                    raise ValueError(f"duplicate map mode in {key}")
                pairs[key][mode] = (iters, checksum, slot, ns)
                groups[(n, side, layout, mask, mode)].append(ns / iters)
                all_rows.append({
                    "run": run, "channels": n, "roi_side": side,
                    "layout": layout, "mask": mask, "round": round_,
                    "slot": slot, "mode": mode, "iterations": iters,
                    "elapsed_ns": ns, "checksum": checksum,
                })
            elif row[0] == "consumer_setup":
                if len(row) != 6:
                    raise ValueError(f"invalid setup record: {row}")
                _, n, mode, iters, ns, checksum = row
                n, iters, ns, checksum = map(int, (n, iters, ns, checksum))
                if mode not in SETUPS or iters <= 0 or ns <= 0:
                    raise ValueError(f"invalid setup: {row}")
                setups[(n, mode)].append(ns / iters)
            elif row[0].startswith("consumer_"):
                continue

    if not n_runs or not pairs or not setups:
        raise ValueError("no usable measurements")
    for key, measures in pairs.items():
        if set(measures) != MODES:
            raise ValueError(f"incomplete paired cycle {key}")
        old = measures["revalidated_image"]
        fast = measures["verified_immutable_image"]
        if old[0] != fast[0] or old[1] != fast[1] or old[2] == fast[2]:
            raise ValueError(f"wrong paired iteration, checksum or slot {key}")
    cases = defaultdict(list)
    for (_, n, side, layout, mask, _), records in pairs.items():
        old = records["revalidated_image"]
        new = records["verified_immutable_image"]
        cases[(n, side, layout, mask)].append({
            "old_ns": old[3] / old[0],
            "new_ns": new[3] / new[0],
            "ratio": old[3] / new[3],
            "saved_ns": (old[3] - new[3]) / old[0],
        })

    summary = []
    for (n, side, layout, mask), samples in sorted(cases.items()):
        old = [s["old_ns"] for s in samples]
        fast = [s["new_ns"] for s in samples]
        ratios = [s["ratio"] for s in samples]
        saved = [s["saved_ns"] for s in samples]
        summary.append({
            "channels": n, "roi_side": side, "layout": layout,
            "mask": mask, "samples": len(samples),
            "old_median_ns": round(median(old), 3),
            "verified_median_ns": round(median(fast), 3),
            "paired_ratio_median": round(median(ratios), 4),
            "paired_saved_median_ns": round(median(saved), 3),
            "paired_saved_mad_ns": round(median_abs_deviation(saved), 3),
        })

    prep = []
    counts = sorted(set(n for n, _ in setups))
    for n in counts:
        for mode in sorted(SETUPS):
            vals = setups.get((n, mode), [])
            if len(vals) != n_runs:
                raise ValueError(f"missing setup: n={n}, mode={mode}")
            prep.append({
                "channels": n, "mode": mode, "samples": len(vals),
                "median_ns": round(median(vals), 3),
                "mad_ns": round(median_abs_deviation(vals), 3),
            })

    options.output.mkdir(parents=True, exist_ok=True)
    with (options.output / "consumer-summary.csv").open(
        "w", encoding="utf-8", newline=""
    ) as f:
        writer = csv.DictWriter(f, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    with (options.output / "consumer-setup.csv").open(
        "w", encoding="utf-8", newline=""
    ) as f:
        writer = csv.DictWriter(f, fieldnames=list(prep[0]))
        writer.writeheader()
        writer.writerows(prep)
    with (options.output / "consumer-raw.csv").open(
        "w", encoding="utf-8", newline=""
    ) as f:
        writer = csv.DictWriter(f, fieldnames=list(all_rows[0]))
        writer.writeheader()
        writer.writerows(all_rows)
    (options.output / "consumer-summary.json").write_text(
        json.dumps({
            "schema": "imagery-d-m3.2.8-consumer-v1",
            "disclaimer": "Microbenchmark of ROI + pixel mapping, not a "
                          "production release or end-to-end decoder metric.",
            "processes": n_runs,
            "paired_cycles": len(pairs),
            "summary": summary,
            "metadata_setup": prep,
        }, indent=2) + "\n", encoding="utf-8")

    print(f"Validated {n_runs} processes, {len(pairs)} paired mapping rounds.")
    for row in summary:
        print(f"{row['channels']:4} {row['roi_side']:2} "
              f"{row['layout']:<11} {row['mask']:<8} "
              f"old {row['old_median_ns']:>10} ns, "
              f"verified {row['verified_median_ns']:>10} ns, "
              f"paired {row['paired_ratio_median']:>6}x")


if __name__ == "__main__":
    main()
