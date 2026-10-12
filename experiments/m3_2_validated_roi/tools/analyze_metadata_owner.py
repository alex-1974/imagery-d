#!/usr/bin/env python3
"""Strict M3.2.17 immutable ownership and repeated Prepared ROI evidence audit.

This compares different caller guarantees, not merely three interchangeable
optimization backends. The physical-pixel checksum is recomputed independently.
"""
import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path

POLICIES = ("immutable", "snapshot_once", "snapshot_each")
FIELDS = (
    "policy", "roi_side", "reuse", "packet", "setup_ns", "map_ns",
    "checksum", "expected", "hot_gc_alloc_bytes", "once_copy_ns",
    "once_copy_alloc_bytes",
)
INTS = ("roi_side", "reuse", "packet", "setup_ns", "map_ns",
        "hot_gc_alloc_bytes", "once_copy_ns", "once_copy_alloc_bytes")
LOGNAME = re.compile(
    r"run-(0|[1-9][0-9]*)-(immutable|snapshot_once|snapshot_each)"
    r"-(8|32)-(4|16)\.log\Z"
)
CFG = re.compile(
    r"^repeats=(\d+) packets=(\d+) sides=([0-9,]+) reuses=([0-9,]+)$",
    re.M
)


def independent_checksum(packet, reuse):
    # M3.2.17 source stores sample c*16+2*y+x, with metadata choice=2
    # and three-channel binding permutation=1 -> first channel n-2=254.
    xs, ys = (0, 3, 13, 29), (0, 7, 17, 23)
    observed = 0.0
    for roi in range(reuse):
        k = (roi + packet) % 4
        x, y = xs[k], ys[k]
        if (x + y) % 11 != 0:
            observed += (254 * 16 + 2 * y + x) * 0.625 - 6.0
    return observed


def config(folder):
    env = (folder / "environment.txt").read_text(encoding="utf-8")
    m = CFG.findall(env)
    if len(m) != 1 or "schema=imagery-d-m3.2.17-metadata-owner-v1" not in env:
        raise ValueError("Incorrect metadata owner evidence header")
    repeats = int(m[0][0])
    packets = int(m[0][1])
    sides = tuple(int(x) for x in m[0][2].split(","))
    reuses = tuple(int(x) for x in m[0][3].split(","))
    if (repeats < 2 or packets < 1 or packets > 8192
            or not sides or set(sides) - {8, 32}
            or len(set(sides)) != len(sides)
            or not reuses or set(reuses) - {4, 16}
            or len(set(reuses)) != len(reuses)):
        raise ValueError("Invalid metadata owner experiment parameters")
    return repeats, packets, sides, reuses


def qualify(folder):
    repeats, packets, sides, reuses = config(folder)
    wanted = {
        (i, policy, side, reuse)
        for i in range(repeats)
        for policy in POLICIES
        for side in sides for reuse in reuses
    }
    files = {}
    for path in folder.glob("run-*.log"):
        m = LOGNAME.fullmatch(path.name)
        if not m:
            raise ValueError("Malformed metadata owner log name")
        key = (int(m[1]), m[2], int(m[3]), int(m[4]))
        if key in files:
            raise ValueError("Duplicate metadata owner process")
        files[key] = path
    if set(files) != wanted:
        raise ValueError("Incomplete/extra metadata owner processes")

    all_rows, process_summaries = [], []
    for (run, policy, side, reuse), path in sorted(files.items()):
        raw = path.read_text(encoding="utf-8")
        if "M3.2.17 PASS: immutable ownership, snapshot isolation and actual ROI pixel oracle" not in raw:
            raise ValueError("Missing D full-pixel completion marker")
        rows, header_seen = [], False
        for record in csv.reader(raw.splitlines()):
            if not record:
                continue
            if record[0] == "metadata_owner_schema":
                if header_seen or record[1:] != list(FIELDS):
                    raise ValueError("Incorrect/duplicate metadata owner schema")
                header_seen = True
            elif record[0] == "metadata_owner_case":
                if len(record) != len(FIELDS) + 1:
                    raise ValueError("Incorrect measured row width")
                row = dict(zip(FIELDS, record[1:]))
                try:
                    for field in INTS:
                        row[field] = int(row[field])
                    row["checksum"] = float(row["checksum"])
                    row["expected"] = float(row["expected"])
                except (ValueError, OverflowError) as err:
                    raise ValueError("Non-numeric metadata owner measurement") from err
                if (row["policy"] != policy or row["roi_side"] != side
                        or row["reuse"] != reuse or row["packet"] != len(rows)):
                    raise ValueError("Incorrect policy/packet/ROI sequence")
                if (row["setup_ns"] < 0 or row["map_ns"] <= 0
                        or row["once_copy_ns"] < 0
                        or row["hot_gc_alloc_bytes"] < 0
                        or row["once_copy_alloc_bytes"] < 0):
                    raise ValueError("Invalid duration or allocation counter")
                value = independent_checksum(row["packet"], reuse)
                if (not math.isfinite(row["checksum"])
                    or not math.isfinite(row["expected"])
                    or not math.isclose(row["checksum"], value, rel_tol=1e-5, abs_tol=1e-4)
                    or not math.isclose(row["expected"], value, rel_tol=1e-5, abs_tol=1e-4)):
                    raise ValueError("Forged/invalid independent mapped-pixel oracle")
                if (policy != "snapshot_once"
                        and (row["once_copy_ns"] != 0 or row["once_copy_alloc_bytes"] != 0)):
                    raise ValueError("Only snapshot_once may report upfront copy")
                if row["packet"] > 0 and (
                        row["once_copy_ns"] != 0 or row["once_copy_alloc_bytes"] != 0):
                    raise ValueError("Repeated supposedly once-only metadata copy")
                if policy == "snapshot_once" and row["packet"] == 0 and row["once_copy_alloc_bytes"] <= 0:
                    raise ValueError("Missing measured one-time snapshot")
                if policy in ("immutable", "snapshot_once") and row["hot_gc_alloc_bytes"] != 0:
                    raise ValueError("GC allocation in promised @nogc reusable Prepared ROI path")
                if policy == "snapshot_each" and row["hot_gc_alloc_bytes"] <= 0:
                    raise ValueError("Missing per-packet immutable snapshots")
                row["run"] = run
                rows.append(row)
                all_rows.append(row)
        if not header_seen or len(rows) != packets:
            raise ValueError("Incomplete metadata owner process/packet matrix")
        process_summaries.append({
            "run": run, "policy": policy, "roi_side": side,
            "reuse": reuse, "packets": len(rows),
            "median_setup_ns": statistics.median(x["setup_ns"] for x in rows),
            "median_map_ns": statistics.median(x["map_ns"] for x in rows),
            "total_setup_ns": sum(x["setup_ns"] for x in rows),
            "total_map_ns": sum(x["map_ns"] for x in rows),
            "total_upfront_copy_ns": sum(x["once_copy_ns"] for x in rows),
            "total_hot_gc_bytes": sum(x["hot_gc_alloc_bytes"] for x in rows),
            "total_upfront_gc_bytes": sum(x["once_copy_alloc_bytes"] for x in rows),
            "max_setup_ns": max(x["setup_ns"] for x in rows)
        })
    if len(all_rows) != len(wanted) * packets:
        raise ValueError("Incomplete global metadata owner matrix")
    return all_rows, process_summaries, {
        "schema": "imagery-d-m3.2.17-metadata-owner-v1",
        "repeats": repeats, "packets": packets,
        "policies": POLICIES, "sides": sides, "reuses": reuses,
        "processes": len(wanted), "observations": len(all_rows),
        "independent_physical_pixel_oracle": "PASS",
        "per_process": process_summaries,
        "limitations": [
            "Immutable caller supplied original creation outside consumer timing.",
            "snapshot_once copies first, but snapshot_each owns different lifetime contracts.",
            "A stopwatch value of zero may reflect 100ns timer granularity.",
            "Hot GC byte counter does not establish zero major/minor faults or bounded tail.",
            "Total selected components are not whole-process wall time.",
            "No zero-copy freeze from mutable storage was performed or admitted."
        ]
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    folder = parser.parse_args().directory
    rows, processes, audit = qualify(folder)
    with (folder / "metadata-owner-raw.csv").open("w", newline="") as dest:
        w = csv.DictWriter(dest, list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    with (folder / "metadata-owner-processes.csv").open("w", newline="") as dest:
        w = csv.DictWriter(dest, list(processes[0]))
        w.writeheader()
        w.writerows(processes)
    (folder / "metadata-owner-summary.json").write_text(
        json.dumps(audit, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {audit['processes']} processes, "
          f"{audit['observations']} independent calibrated records")
    print("No mutable-to-immutable zero-copy freeze is implied.")


if __name__ == "__main__":
    main()
