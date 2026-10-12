#!/usr/bin/env python3
"""Strict audit of complete paired M3.2.14 ROI-reuse measurements.

A valid log has all expected run/layout/policy/reuse/round/slot tuples,
balanced method positions and an independently recomputed pixel checksum.
Pass does NOT imply a performance win, suitable GC behavior or break-even.
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
LAYOUTS = ("planar", "interleaved")
POLICIES = ("immutable", "mutable_snapshot")
REUSE = (1, 2, 4, 8, 16, 32)
MODES = ("one_shot", "prepared")
PARAM = re.compile(
    r"^repeats=(\d+) rounds=(\d+) warmups=(\d+) smoke=(0|1)$",
    re.MULTILINE,
)
LOG = re.compile(r"run-(0|[1-9][0-9]*)\.log\Z")
FIELDS = (
    "channels", "roi_side", "layout", "mask", "policy", "reuse", "round",
    "slot", "mode", "setup_ns", "map_ns", "total_ns", "checksum", "expected"
)


def expected_sum(n, side, policy, count, round_abs, mask):
    # The input choice and band permutation in the D runner do not
    # depend on the policy: both sides get the same semantic input.
    choice = (round_abs * 5 + count) % 8
    permutation = (round_abs + count) % 3
    first_band = (n - 1, n - 2, n - 3)[permutation]
    cal_scale = 0.5 + choice * 0.0625
    cal_offset = -4.0 - choice
    xs, ys = (0, 3, 13, 29), (0, 7, 17, 23)
    total = 0.0
    for i in range(count):
        x = xs[(i + round_abs) % 4]
        y = ys[(i + round_abs) % 4]
        value = (0.0 if mask == "masked" and (x + y) % 11 == 0
                 else (first_band * 16 + y * 2 + x) * cal_scale + cal_offset)
        total += value
    return total


def parameters(path):
    text = (path / "environment.txt").read_text(encoding="utf-8")
    found = PARAM.findall(text)
    if len(found) != 1:
        raise ValueError("missing or ambiguous reuse runner parameters")
    repeat, rounds, warmups, smoke = map(int, found[0])
    if repeat <= 0 or rounds <= 0 or rounds % 2 or warmups < 0:
        raise ValueError("invalid or imbalanced reuse parameters")
    return repeat, rounds, warmups, bool(smoke)


def qualify(directory):
    repeats, rounds, warmups, smoke = parameters(directory)
    channels = CHANNELS[:2] if smoke else CHANNELS
    sides = SIDES[:1] if smoke else SIDES
    process_files = {}
    for p in directory.glob("run-*.log"):
        match = LOG.fullmatch(p.name)
        if match is None:
            raise ValueError(f"invalid process file name: {p.name}")
        index = int(match[1])
        if index in process_files:
            raise ValueError("duplicate process log")
        process_files[index] = p
    if set(process_files) != set(range(repeats)):
        raise ValueError("missing or additional process logs")

    seen = set()
    rows = []
    pairs = defaultdict(dict)
    slots = defaultdict(int)
    for run, path in sorted(process_files.items()):
        contents = path.read_text(encoding="utf-8")
        if "M3.2.14 PASS: paired reuse, full pixels and calibrated oracle" not in contents:
            raise ValueError(f"missing program pass marker: {path.name}")
        for item in csv.reader(contents.splitlines()):
            if not item or item[0] != "reuse_case":
                continue
            if len(item) != len(FIELDS) + 1:
                raise ValueError(f"invalid reuse schema: {item}")
            value = dict(zip(FIELDS, item[1:]))
            try:
                n = int(value["channels"])
                side = int(value["roi_side"])
                reuse = int(value["reuse"])
                rnd = int(value["round"])
                slot = int(value["slot"])
                setup = int(value["setup_ns"])
                mapped = int(value["map_ns"])
                total = int(value["total_ns"])
                checksum = float(value["checksum"])
                expected = float(value["expected"])
            except (ValueError, OverflowError) as exc:
                raise ValueError(f"invalid numeric row: {item}") from exc
            layout, mask, policy, mode = (
                value[x] for x in ("layout", "mask", "policy", "mode")
            )
            if (n not in channels or side not in sides
                    or layout not in LAYOUTS or policy not in POLICIES
                    or reuse not in REUSE or not 0 <= rnd < rounds
                    or slot not in (0, 1)):
                raise ValueError(f"unexpected benchmark dimension: {item}")
            if mask != ("masked" if layout == "planar" else "unmasked"):
                raise ValueError(f"inconsistent source layout and mask: {item}")
            if mode != MODES[(rnd + warmups + slot) % 2]:
                raise ValueError(f"invalid rotated method order: {item}")
            # Stopwatch resolution can legitimately quantize very short
            # setup phases to 0 ns; negative times or zero-duration full
            # mappings/batches remain invalid. Do not substitute 1 ns.
            if setup < 0 or mapped <= 0 or total <= 0:
                raise ValueError(f"non-positive timed phase: {item}")
            oracle = expected_sum(n, side, policy, reuse, rnd + warmups, mask)
            if not all(map(math.isfinite, (checksum, expected))):
                raise ValueError(f"nonfinite checksum: {item}")
            # D writeln's default float formatting may round text; the
            # executable itself checks exact equality before emission.
            if (not math.isclose(checksum, oracle, rel_tol=1e-5, abs_tol=1e-4)
                    or not math.isclose(expected, oracle, rel_tol=1e-5, abs_tol=1e-4)):
                raise ValueError(f"independent calibrated pixel oracle mismatch: {item}")
            key = (run, n, side, layout, policy, reuse, rnd, slot)
            if key in seen:
                raise ValueError(f"duplicate measurement: {key}")
            seen.add(key)
            paired_key = key[:-1]
            pairs[paired_key][mode] = (total, checksum)
            slots[(n, side, layout, policy, reuse, mode, slot)] += 1
            rows.append({
                "run": run, "channels": n, "roi_side": side, "layout": layout,
                "mask": mask, "policy": policy, "reuse": reuse,
                "round": rnd, "slot": slot, "mode": mode,
                "setup_ns": setup, "map_ns": mapped, "total_ns": total,
                "checksum": checksum, "expected": expected
            })

    expected_keys = {
        (run, n, side, layout, policy, reuse, rnd, slot)
        for run in range(repeats) for n in channels for side in sides
        for layout in LAYOUTS for policy in POLICIES for reuse in REUSE
        for rnd in range(rounds) for slot in range(2)
    }
    if seen != expected_keys:
        missing = sorted(expected_keys - seen)
        extra = sorted(seen - expected_keys)
        raise ValueError(
            f"incomplete reuse measurement matrix missing={missing[:3]} extra={extra[:3]}"
        )
    for key, val in pairs.items():
        if set(val) != set(MODES):
            raise ValueError(f"unpaired alternatives: {key}")
        if not math.isclose(val["one_shot"][1], val["prepared"][1],
                            rel_tol=1e-6, abs_tol=1e-4):
            raise ValueError(f"paired checksum mismatch: {key}")
    per_slot = repeats * rounds // 2
    if any(slots[(n, side, layout, policy, count, mode, slot)] != per_slot
           for n in channels for side in sides for layout in LAYOUTS
           for policy in POLICIES for count in REUSE
           for mode in MODES for slot in range(2)):
        raise ValueError("unbalanced method slots")

    groups = defaultdict(list)
    for row in rows:
        groups[(
            row["channels"], row["roi_side"], row["layout"],
            row["policy"], row["reuse"], row["mode"]
        )].append(row)
    summary = []
    for key, group in sorted(groups.items()):
        values = {col: [x[col] for x in group]
                  for col in ("setup_ns", "map_ns", "total_ns")}
        summary.append({
            "channels": key[0], "roi_side": key[1],
            "layout": key[2], "policy": key[3],
            "reuse": key[4], "mode": key[5],
            "observations": len(group),
            "processes": len({x["run"] for x in group}),
            **{f"median_{col}": round(statistics.median(v), 3)
               for col, v in values.items()},
            "mad_total_ns": round(
                statistics.median(abs(x - statistics.median(values["total_ns"]))
                                  for x in values["total_ns"]), 3
            )
        })
    paired_deltas = defaultdict(list)
    for key, val in pairs.items():
        # key = run,n,side,layout,policy,reuse,round
        _, n, side, layout, policy, reuse, _ = key
        paired_deltas[(n, side, layout, policy, reuse)].append(
            val["one_shot"][0] - val["prepared"][0]
        )
    paired_summary = [
        {
            "channels": key[0], "roi_side": key[1], "layout": key[2],
            "policy": key[3], "reuse": key[4],
            "median_one_shot_minus_prepared_ns": round(statistics.median(x), 3),
            "observations": len(x)
        }
        for key, x in sorted(paired_deltas.items())
    ]
    return rows, summary, {
        "schema": "imagery-d-m3.2.14-reuse-v1",
        "processes": repeats, "rounds": rounds, "warmups": warmups,
        "smoke": smoke, "measurements": len(rows),
        "paired_cycles": len(pairs), "balanced_slots": True,
        "oracle": "independent physical-value 1st pixel per ROI",
        "cases": summary, "paired_cases": paired_summary,
        "caveats": (
            "Benchmark totals include timers and recorded method overhead. "
            "Mutable policy is asymmetric: one-shot borrows, Prepared snapshots. "
            "End-to-end full-pixel correctness is separately checked by D; "
            "a recorded 0 ns setup is timer-quantized, not a free setup. "
            "Hosted timing is smoke, not performance evidence. "
            "No universal break-even may be inferred automatically."
        ),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    folder = p.parse_args().directory
    rows, summary, report = qualify(folder)
    with (folder / "reuse-raw.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (folder / "reuse-summary.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    (folder / "reuse-summary.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print("PASS:", report["processes"], "processes,",
          report["paired_cycles"], "paired cycles,",
          report["measurements"], "measurements; full matrix and oracle verified")
    print("This is evidence integrity only, not a release performance verdict.")


if __name__ == "__main__":
    main()
