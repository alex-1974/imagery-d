#!/usr/bin/env python3
"""Validate real, input-varying M3.2.13 setup evidence; stdlib only."""
import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

MODES = (
    "borrow_validate", "immutable_verify",
    "unified_binding_only", "snapshot_and_verify"
)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("evidence", type=Path)
    args = p.parse_args()
    logpaths = sorted(args.evidence.glob("run-*.log"))
    if not logpaths:
        raise ValueError("No independent run-N.log files")
    rows = []
    blocks = defaultdict(dict)
    slots = defaultdict(int)
    for log in logpaths:
        run = int(log.stem.split("-")[-1])
        for fields in csv.reader(log.read_text(encoding="utf-8").splitlines()):
            if not fields or fields[0] != "setup_challenge":
                continue
            if len(fields) != 9:
                raise ValueError(f"Bad row schema in {log}: {fields}")
            _, n, round_, slot, mode, count, ns, checksum, expected = fields
            n, round_, slot, count, ns, checksum, expected = map(
                int, (n, round_, slot, count, ns, checksum, expected))
            if mode not in MODES or not (0 <= slot <= 3):
                raise ValueError(f"Unknown mode/slot: {fields}")
            if count <= 0 or ns <= 0 or checksum <= 0 or checksum != expected:
                raise ValueError(f"Unverified or empty measurement: {fields}")
            key = (run, n, round_)
            if mode in blocks[key]:
                raise ValueError(f"Duplicate mode in {key}: {mode}")
            blocks[key][mode] = (slot, count, checksum)
            slots[(n, mode, slot)] += 1
            rows.append({
                "run": run, "channels": n, "round": round_,
                "slot": slot, "mode": mode, "iterations": count,
                "elapsed_ns": ns, "checksum": checksum,
                "expected": expected, "ns_per_prep": ns / count
            })
    if not rows:
        raise ValueError("No challenge rows")
    for key, results in blocks.items():
        if set(results) != set(MODES):
            raise ValueError(f"Incomplete 4-path cycle {key}")
        if sorted(t[0] for t in results.values()) != [0, 1, 2, 3]:
            raise ValueError(f"Bad execution slots for {key}")
        if len({t[1] for t in results.values()}) != 1:
            raise ValueError(f"Different iterations in {key}")
        if len({t[2] for mode, t in results.items() if mode != "unified_binding_only"}) != 1:
            raise ValueError(f"Not all metadata methods used same inputs: {key}")

    cases = defaultdict(list)
    for row in rows:
        cases[(row["channels"], row["mode"])].append(row)
    summary = []
    for (n, mode), group in sorted(cases.items()):
        vals = [r["ns_per_prep"] for r in group]
        med = statistics.median(vals)
        summary.append({
            "channels": n, "mode": mode, "observations": len(vals),
            "median_ns": round(med, 3),
            "mad_ns": round(statistics.median(
                [abs(v-med) for v in vals]), 3),
            "median_process_count": len({r["run"] for r in group})
        })
    pth = args.evidence
    with (pth / "setup-challenge-raw.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    with (pth / "setup-challenge-summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0]))
        w.writeheader()
        w.writerows(summary)
    allSlotsBalanced = all(
        len({slots[(n, mode, slot)] for slot in range(4)}) == 1
        for (n, mode) in cases
    )
    output = {
        "schema": "imagery-d-m3.2.13-setup-challenge-v1",
        "source": "separate run-N.log program processes",
        "processes": len(logpaths), "complete_cycles": len(blocks),
        "sample_count": len(rows), "balanced_slots": allSlotsBalanced,
        "cases": summary,
        "caveats": (
            "This is a stronger input-varying anti-hoist challenge, not "
            "a proof of zero compiler transformations or of stable "
            "GC allocation/clock behavior. CPU, allocation, and "
            "consumer reuse gates remain separate."
        )
    }
    (pth / "setup-challenge-summary.json").write_text(
        json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print("PASS:", len(logpaths), "processes,", len(blocks),
          "complete four-route cycles,", len(rows), "timings.")
    print("Balanced execution slots:", allSlotsBalanced)
    for x in summary:
        print(x["channels"], x["mode"], x["median_ns"], "ns",
              "MAD", x["mad_ns"])

if __name__ == "__main__":
    main()
