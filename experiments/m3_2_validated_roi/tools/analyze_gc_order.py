#!/usr/bin/env python3
"""Strict M3.2.15 counterbalanced GC/page-fault ROI research evidence audit.

The deterministic case schedule, checksums and recorded GC/rusage statistics
are verified independently of the D benchmark. This program accepts *no*
automatic causal claim: a GC collection coinciding with a pause is evidence
of association, not proof that a particular stop-the-world event caused it.
"""
import argparse
import csv
import json
import math
import re
import statistics
from collections import defaultdict
from pathlib import Path

CHANNELS = (3, 17, 64, 256)
SIDES = (8, 32)
REUSE = (1, 2, 4, 8, 16, 32)
LAYOUTS = ("planar", "interleaved")
POLICIES = ("immutable", "mutable_snapshot")
MODES = ("one_shot", "prepared")
FIELDS = (
    "case_rank", "order_seed", "channels", "roi_side", "layout", "mask",
    "policy", "reuse", "round", "slot", "mode", "setup_ns", "map_ns",
    "total_ns", "checksum", "expected", "gc_alloc_bytes", "gc_collections",
    "gc_pause_ns", "minor_faults", "major_faults"
)
INTEGERS = set(FIELDS) - {
    "layout", "mask", "policy", "mode", "checksum", "expected"
}
PARAM = re.compile(
    r"^repeats=(\d+) rounds=(\d+) warmups=(\d+) smoke=(0|1)$",
    re.MULTILINE,
)
LOG_NAME = re.compile(r"run-(0|[1-9][0-9]*)\.log\Z")


def order_cases(seed, smoke):
    """Exact independent replay of D's outer channel/ROI/layout/case order."""
    channels = CHANNELS[:2] if smoke else CHANNELS
    sides = SIDES[:1] if smoke else SIDES
    results = []
    for nr in range(len(channels)):
        n = channels[(nr + seed) % len(channels)]
        for sr in range(len(sides)):
            side = sides[(sr + seed // 2) % len(sides)]
            for lr in range(2):
                layout = LAYOUTS[(lr + seed) % 2]
                mask = "masked" if layout == "planar" else "unmasked"
                for slot in range(12):
                    idx = (slot * 5 + seed * 7) % 12
                    policy = POLICIES[idx // 6]
                    count = REUSE[idx % 6]
                    rank = ((nr * len(sides) + sr) * 2 + lr) * 12 + slot
                    results.append((rank, n, side, layout, mask, policy, count))
    return results


def expected_sum(n, count, absolute_round, permutation, choice, mask):
    """Independent physical pixel oracle (first sample from every ROI)."""
    band = (n - 1, n - 2, n - 3)[permutation]
    scale = 0.5 + 0.0625 * choice
    offset = -4.0 - choice
    xs = (0, 3, 13, 29)
    ys = (0, 7, 17, 23)
    sum_ = 0.0
    for i in range(count):
        idx = (i + absolute_round) % 4
        x, y = xs[idx], ys[idx]
        if mask == "masked" and (x + y) % 11 == 0:
            sum_ += 0.0
        else:
            sum_ += (band * 16 + y * 2 + x) * scale + offset
    return sum_


def parameters(folder):
    contents = (folder / "environment.txt").read_text(encoding="utf-8")
    matches = PARAM.findall(contents)
    if len(matches) != 1:
        raise ValueError("Missing or ambiguous GC-order runner parameters")
    repeats, rounds, warmups, smoke = map(int, matches[0])
    if repeats < 2 or rounds <= 0 or rounds % 2 or warmups < 0:
        raise ValueError("Counterbalance needs >=2 processes and even rounds")
    if "schema=imagery-d-m3.2.15-gc-order-v1" not in contents:
        raise ValueError("Wrong evidence schema")
    return repeats, rounds, warmups, bool(smoke)


def qualify(folder):
    repeats, rounds, warmups, smoke = parameters(folder)
    logfiles = {}
    for path in folder.glob("run-*.log"):
        m = LOG_NAME.fullmatch(path.name)
        if m is None:
            raise ValueError(f"Malformed run log name: {path.name}")
        run = int(m[1])
        if run in logfiles:
            raise ValueError("Duplicate process file")
        logfiles[run] = path
    if set(logfiles) != set(range(repeats)):
        raise ValueError(f"Missing or additional processes {sorted(logfiles)}")

    rows = []
    case_pairs = defaultdict(dict)
    for run, path in sorted(logfiles.items()):
        raw = path.read_text(encoding="utf-8")
        if "M3.2.15 PASS: counterbalanced order and instrumented ROI oracle" not in raw:
            raise ValueError(f"Missing D-run completion marker in {path}")
        found_header = False
        parsed = []
        for csvrow in csv.reader(raw.splitlines()):
            if not csvrow:
                continue
            if csvrow[0] == "reuse_gc_schema":
                if found_header or csvrow[1:] != list(FIELDS):
                    raise ValueError(f"Missing/incorrect schema header in {path}")
                found_header = True
                continue
            if csvrow[0] != "reuse_gc_case":
                continue
            if len(csvrow) != 1 + len(FIELDS):
                raise ValueError(f"Incorrect measured row width in {path}")
            obj = dict(zip(FIELDS, csvrow[1:]))
            try:
                for field in INTEGERS:
                    obj[field] = int(obj[field])
                for field in ("checksum", "expected"):
                    obj[field] = float(obj[field])
            except ValueError as error:
                raise ValueError(f"Incorrect numeric value in {path}: {csvrow}") from error
            if obj["order_seed"] != run:
                raise ValueError(f"Run seed mismatch in {path}")
            if min(obj[k] for k in ("setup_ns", "gc_alloc_bytes",
                   "gc_collections", "gc_pause_ns", "minor_faults", "major_faults")) < 0:
                raise ValueError("Negative setup or negative GC/rusage delta")
            if obj["map_ns"] <= 0 or obj["total_ns"] <= 0:
                raise ValueError("Nonpositive measured map/total time")
            if not all(math.isfinite(obj[k]) for k in ("checksum", "expected")):
                raise ValueError("Nonfinite checksum or expected")
            parsed.append(obj)
        if not found_header:
            raise ValueError(f"Missing benchmark header in {path}")

        expected_sequence = [
            (rank, n, side, layout, mask, policy, count, rnd, slot,
             MODES[(rnd + warmups + slot) % 2])
            for rank, n, side, layout, mask, policy, count in order_cases(run, smoke)
            for rnd in range(rounds)
            for slot in range(2)
        ]
        if len(parsed) != len(expected_sequence):
            raise ValueError(f"Incomplete process/case matrix in {path}: "
                             f"{len(parsed)} rather than {len(expected_sequence)}")
        for obj, expect in zip(parsed, expected_sequence):
            got = (obj["case_rank"], obj["channels"], obj["roi_side"],
                   obj["layout"], obj["mask"], obj["policy"], obj["reuse"],
                   obj["round"], obj["slot"], obj["mode"])
            if got != expect:
                raise ValueError(f"Incorrect deterministic case order in {path}: "
                                 f"got={got} expected={expect}")
            absolute = obj["round"] + warmups
            choice = (absolute * 5 + obj["reuse"]) % 8
            permutation = (absolute + obj["reuse"]) % 3
            computed = expected_sum(obj["channels"], obj["reuse"],
                                    absolute, permutation, choice, obj["mask"])
            if (not math.isclose(obj["checksum"], computed, rel_tol=1e-5, abs_tol=1e-4)
                    or not math.isclose(obj["expected"], computed,
                                        rel_tol=1e-5, abs_tol=1e-4)):
                raise ValueError(f"Independent pixel checksum mismatch in {path}: {obj}")
            obj["run"] = run
            rows.append(obj)
            pairkey = (run, obj["channels"], obj["roi_side"],
                       obj["layout"], obj["policy"], obj["reuse"], obj["round"])
            if obj["mode"] in case_pairs[pairkey]:
                raise ValueError(f"Duplicate pair alternative: {pairkey}")
            case_pairs[pairkey][obj["mode"]] = obj

    if any(set(pair) != set(MODES) or
           pair["one_shot"]["checksum"] != pair["prepared"]["checksum"]
           for pair in case_pairs.values()):
        raise ValueError("Unpaired or disagreeing matched pixel outputs")

    groups = defaultdict(list)
    for row in rows:
        key = (row["channels"], row["roi_side"], row["layout"],
               row["policy"], row["reuse"], row["mode"])
        groups[key].append(row)
    cases = []
    for key, data in sorted(groups.items()):
        durations = [v["total_ns"] for v in data]
        dmedian = statistics.median(durations)
        cases.append({
            "channels": key[0], "roi_side": key[1], "layout": key[2],
            "policy": key[3], "reuse": key[4], "mode": key[5],
            "observations": len(data), "processes": len(set(v["run"] for v in data)),
            "median_setup_ns": statistics.median(v["setup_ns"] for v in data),
            "median_map_ns": statistics.median(v["map_ns"] for v in data),
            "median_total_ns": dmedian,
            "mad_total_ns": statistics.median(abs(v-dmedian) for v in durations),
            "max_setup_ns": max(v["setup_ns"] for v in data),
            "over_50us_setups": sum(v["setup_ns"] > 50_000 for v in data),
            "observed_gc_cycles": sum(v["gc_collections"] for v in data),
            "observed_gc_alloc_bytes": sum(v["gc_alloc_bytes"] for v in data),
            "observed_minor_faults": sum(v["minor_faults"] for v in data),
            "observed_major_faults": sum(v["major_faults"] for v in data)
        })
    tails = [
        {
            "run": x["run"], "case_rank": x["case_rank"],
            "channels": x["channels"], "roi_side": x["roi_side"],
            "layout": x["layout"], "policy": x["policy"],
            "reuse": x["reuse"], "round": x["round"],
            "slot": x["slot"], "mode": x["mode"],
            "setup_ns": x["setup_ns"], "total_ns": x["total_ns"],
            "gc_alloc_bytes": x["gc_alloc_bytes"],
            "gc_collections": x["gc_collections"],
            "gc_pause_ns": x["gc_pause_ns"],
            "minor_faults": x["minor_faults"],
            "major_faults": x["major_faults"]
        }
        for x in rows if x["setup_ns"] > 50_000
    ]
    expected_pairs = repeats * len(order_cases(0, smoke)) * rounds
    if len(case_pairs) != expected_pairs:
        raise ValueError("Incomplete pairs")
    return rows, cases, {
        "schema": "imagery-d-m3.2.15-gc-order-v1",
        "processes": repeats, "rounds": rounds, "warmups": warmups,
        "smoke": smoke, "measurement_count": len(rows),
        "paired_cycles": len(case_pairs), "counterbalanced_order": True,
        "independent_pixel_oracle": "PASS", "case_count": len(cases),
        "tails_above_50us": tails,
        "cases": cases,
        "caveats": (
            "GC.stats and getrusage are sampled immediately outside timers, "
            "but the instrumentation can change subsequent workload state. "
            "A GC cycle delta is temporal association, not causal proof. "
            "Uncontrolled hosted timing cannot qualify break-even or tails."
        )
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    folder = p.parse_args().directory
    rows, summary, report = qualify(folder)
    with (folder / "gc-order-raw.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (folder / "gc-order-summary.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    (folder / "gc-order-summary.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print("PASS:", report["processes"], "processes,",
          report["paired_cycles"], "paired cases,",
          report["measurement_count"], "rows;",
          "independent pixel and deterministic order gates accepted")
    print("Observed >50us setups:", len(report["tails_above_50us"]))
    print("GC and rusage counters are observational, not causal proof.")


if __name__ == "__main__":
    main()
