#!/usr/bin/env python3
"""Qualify complete M3.2.13 setup evidence; replay independent input oracle.

All constraints are keyed by the runner's own environment.txt. No incomplete
runs, skewed execution slots, or self-consistent but forged checksums pass.
"""
import argparse
import csv
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path

MODES = (
    "borrow_validate", "immutable_verify",
    "unified_binding_only", "snapshot_and_verify",
)
CHANNELS = (3, 17, 64, 256)
MASK32 = (1 << 32) - 1
RUN_RE = re.compile(r"run-(0|[1-9][0-9]*)\.log\Z")
PARAM_RE = re.compile(
    r"^repeats=(\d+) rounds=(\d+) iterations=(\d+) warmups=(\d+)$",
    re.MULTILINE,
)


def parameters(folder):
    text = (folder / "environment.txt").read_text(encoding="utf-8")
    matches = PARAM_RE.findall(text)
    if len(matches) != 1:
        raise ValueError("Expected precisely one runner parameter record")
    repeats, rounds, iterations, warmups = map(int, matches[0])
    if min(repeats, rounds, iterations) <= 0 or warmups < 0:
        raise ValueError("Invalid runner parameter record")
    if rounds % 4:
        raise ValueError("Rounds must be divisible by four for balanced slots")
    return repeats, rounds, iterations, warmups


def expected_checksum(mode, iterations, actual_round, cache):
    key = (mode, iterations, actual_round)
    if key not in cache:
        # D's uint seed and challengeNext use wrapping uint32 arithmetic.
        state = (0x6A09E667 + actual_round * 2654435761) & MASK32
        checksum = 0
        for _ in range(iterations):
            state = (state * 1664525 + 1013904223) & MASK32
            select = (state >> 24) % 8
            checksum += 1 if mode == "unified_binding_only" else 24000 + select * 1024
        cache[key] = checksum
    return cache[key]


def qualify(folder):
    repeats, rounds, iterations, warmups = parameters(folder)
    paths = list(folder.glob("run-*.log"))
    process_files = {}
    for p in paths:
        match = RUN_RE.fullmatch(p.name)
        if match is None:
            raise ValueError(f"Invalid process log name: {p.name}")
        run = int(match[1])
        if run in process_files:
            raise ValueError(f"Duplicate process log: {p}")
        process_files[run] = p
    if set(process_files) != set(range(repeats)):
        raise ValueError(f"Missing/extra processes: got {sorted(process_files)}, expected {repeats}")

    rows = []
    seen = set()
    slots = defaultdict(int)
    oracle_cache = {}
    for run, log in sorted(process_files.items()):
        body = log.read_text(encoding="utf-8")
        if "M3.2.13 PASS: runtime-selected preparation oracle" not in body:
            raise ValueError(f"Missing successful D-run completion marker in {log}")
        for record in csv.reader(body.splitlines()):
            if not record or record[0] != "setup_challenge":
                continue
            if len(record) != 9:
                raise ValueError(f"Bad row schema in {log}: {record}")
            _, n, rnd, slot, mode, count, ns, checksum, expected = record
            n, rnd, slot, count, ns, checksum, expected = map(
                int, (n, rnd, slot, count, ns, checksum, expected)
            )
            if n not in CHANNELS or rnd not in range(rounds) or slot not in range(4):
                raise ValueError(f"Unexpected channels/round/slot: {record}")
            if mode not in MODES or mode != MODES[(rnd + warmups + slot) % 4]:
                raise ValueError(f"Wrong mode for rotated slot: {record}")
            if count != iterations or ns <= 0:
                raise ValueError(f"Wrong iteration count or elapsed time: {record}")
            reference = expected_checksum(mode, iterations, rnd + warmups, oracle_cache)
            if checksum != reference or expected != reference:
                raise ValueError(f"Independent LCG checksum mismatch in {log}: {record}")
            key = (run, n, rnd, slot)
            if key in seen:
                raise ValueError(f"Duplicate run/channel/round/slot: {key}")
            seen.add(key)
            slots[(n, mode, slot)] += 1
            rows.append({
                "run": run, "channels": n, "round": rnd, "slot": slot,
                "mode": mode, "iterations": count, "elapsed_ns": ns,
                "checksum": checksum, "expected": expected,
                "ns_per_prep": ns / count,
            })
    expected_keys = {
        (run, n, rnd, slot)
        for run in range(repeats) for n in CHANNELS
        for rnd in range(rounds) for slot in range(4)
    }
    if seen != expected_keys:
        missing = sorted(expected_keys - seen)
        extra = sorted(seen - expected_keys)
        raise ValueError(f"Incomplete measurement matrix: missing={missing[:5]}, extra={extra[:5]}")
    needed_per_slot = repeats * rounds // 4
    if any(slots[(n, mode, slot)] != needed_per_slot
           for n in CHANNELS for mode in MODES for slot in range(4)):
        raise ValueError("Imbalanced method execution positions")

    groups = defaultdict(list)
    for row in rows:
        groups[(row["channels"], row["mode"])].append(row)
    summary = []
    for (n, mode), group in sorted(groups.items()):
        vals = [r["ns_per_prep"] for r in group]
        med = statistics.median(vals)
        summary.append({
            "channels": n, "mode": mode, "observations": len(vals),
            "median_ns": round(med, 3),
            "mad_ns": round(statistics.median(abs(v - med) for v in vals), 3),
            "median_process_count": len({r["run"] for r in group}),
        })
    if len(summary) != len(CHANNELS) * len(MODES):
        raise ValueError("Missing channel/mode summary")
    return rows, summary, {
        "schema": "imagery-d-m3.2.13-setup-challenge-v1",
        "source": "separate run-N.log program processes, independently replayed uint32 LCG",
        "processes": repeats, "complete_cycles": len(expected_keys) // 4,
        "sample_count": len(rows), "balanced_slots": True,
        "iterations": iterations, "rounds": rounds, "warmups": warmups,
        "cases": summary,
        "caveats": (
            "Correct raw evidence and balanced input selectors do not establish "
            "full optimizer-visible preparation, GC/frequency stability, "
            "pixel-consumer performance, or break-even."
        ),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    folder = parser.parse_args().evidence
    rows, summary, report = qualify(folder)
    # Write artifacts only after all integrity gates passed.
    with (folder / "setup-challenge-raw.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (folder / "setup-challenge-summary.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    (folder / "setup-challenge-summary.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print("PASS:", report["processes"], "processes,",
          report["complete_cycles"], "complete four-route cycles,",
          report["sample_count"], "timings.")
    print("Balanced execution slots: True; independent uint32 oracle: PASS")
    for row in summary:
        print(row["channels"], row["mode"], row["median_ns"], "ns",
              "MAD", row["mad_ns"])


if __name__ == "__main__":
    main()
