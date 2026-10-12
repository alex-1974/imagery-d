#!/usr/bin/env python3
"""M3.2.20 source-independent scoped Prepared session evidence audit."""
import argparse
import csv
import json
import math
import re
from pathlib import Path

POLICIES = ("reprepare", "session")
PHASES = ("original", "refreshed")
ROI_FIELDS = (
    "policy", "phase", "packet", "roi", "roi_side", "reuse",
    "x", "y", "first0", "first1", "first2", "last0", "last1", "last2"
)
CASE_FIELDS = (
    "policy", "phase", "roi_side", "reuse", "packets", "elapsed_ns",
    "hot_gc_bytes", "preparations", "roi_maps"
)
ROI_INTS = ("packet", "roi", "roi_side", "reuse", "x", "y")
ROI_FLOATS = ("first0", "first1", "first2", "last0", "last1", "last2")
CASE_INTS = ("roi_side", "reuse", "packets", "elapsed_ns",
             "hot_gc_bytes", "preparations", "roi_maps")
LOG = re.compile(r"run-(0|[1-9][0-9]*)-(reprepare|session)-(8|32)-(4|16)\.log\Z")
CONFIG = re.compile(
    r"^repeats=(\d+) packets=(\d+) sides=([0-9,]+) reuses=([0-9,]+)$", re.M)
XS = (0, 3, 13, 29)
YS = (0, 7, 17, 23)
CHANNELS = (254, 253, 255)


def expected_pixel(phase, component, x, y):
    if (x + y) % 11 == 0:
        return 0.0
    choice = 2 if phase == "original" else 3
    return ((CHANNELS[component] * 16 + y * 2 + x)
            * (0.5 + choice * 0.0625) - 4 - choice)


def parse(cells, fields, ints, floats=()):
    if len(cells) != len(fields) + 1:
        raise ValueError("Wrong evidence row width")
    row = dict(zip(fields, cells[1:]))
    try:
        for field in ints:
            row[field] = int(row[field])
        for field in floats:
            row[field] = float(row[field])
    except (ValueError, OverflowError) as exc:
        raise ValueError("Malformed evidence number") from exc
    return row


def audit(folder):
    env = (folder / "environment.txt").read_text()
    if "schema=imagery-d-m3.2.20-scoped-prepared-session-v1" not in env:
        raise ValueError("Missing correct evidence schema")
    matches = CONFIG.findall(env)
    if len(matches) != 1:
        raise ValueError("Incomplete process configuration")
    repeats, packets = int(matches[0][0]), int(matches[0][1])
    sides = tuple(map(int, matches[0][2].split(",")))
    reuses = tuple(map(int, matches[0][3].split(",")))
    if (repeats < 2 or not 1 <= packets <= 8192
            or not sides or len(set(sides)) != len(sides)
            or set(sides) - {8, 32}
            or not reuses or len(set(reuses)) != len(reuses)
            or set(reuses) - {4, 16}):
        raise ValueError("Invalid process matrix")

    wanted = {
        (repeat, mode, side, reuse)
        for repeat in range(repeats)
        for mode in POLICIES for side in sides for reuse in reuses
    }
    logs = {}
    for path in folder.glob("run-*.log"):
        match = LOG.fullmatch(path.name)
        if not match:
            raise ValueError("Unrecognized run log")
        key = (int(match[1]), match[2], int(match[3]), int(match[4]))
        if key in logs:
            raise ValueError("Duplicate process")
        logs[key] = path
    if set(logs) != wanted:
        raise ValueError("Missing/extra process log")

    observations, timings, process_summaries = [], [], []
    for (repeat, policy, side, reuse), path in sorted(logs.items()):
        lines = path.read_text().splitlines()
        marker = ("M3.2.20 PASS: scoped multi-packet Prepared lifetime, "
                  "ordered physical ROIs and zero mapping GC")
        if sum(marker in line for line in lines) != 1:
            raise ValueError("Missing/duplicate full semantic PASS")
        header_roi, header_case = 0, 0
        roi_rows, case_rows = [], []
        for cells in csv.reader(lines):
            if not cells:
                continue
            tag = cells[0]
            if tag == "prepared_session_roi_schema":
                header_roi += 1
                if cells[1:] != list(ROI_FIELDS):
                    raise ValueError("Incorrect per-ROI schema")
            elif tag == "prepared_session_schema":
                header_case += 1
                if cells[1:] != list(CASE_FIELDS):
                    raise ValueError("Incorrect phase summary schema")
            elif tag == "prepared_session_roi":
                row = parse(cells, ROI_FIELDS, ROI_INTS, ROI_FLOATS)
                index = len(roi_rows)
                phase_num = index // (packets * reuse)
                if phase_num >= 2:
                    raise ValueError("Unexpected extra ROI")
                phase = PHASES[phase_num]
                packet = (index // reuse) % packets
                roi = index % reuse
                k = (packet + roi) % 4
                if (row["policy"] != policy or row["phase"] != phase
                    or row["packet"] != packet or row["roi"] != roi
                    or row["roi_side"] != side or row["reuse"] != reuse
                    or row["x"] != XS[k] or row["y"] != YS[k]):
                    raise ValueError("Missing/swapped/forged ROI index or position")
                for component in range(3):
                    for prefix, x, y in (
                        ("first", XS[k], YS[k]),
                        ("last", XS[k] + side - 1, YS[k] + side - 1)
                    ):
                        got = row[f"{prefix}{component}"]
                        expected = expected_pixel(phase, component, x, y)
                        if (not math.isfinite(got)
                            or not math.isclose(got, expected,
                                                rel_tol=0, abs_tol=0.01001)):
                            raise ValueError("Forged/invalid physical pixel")
                row["repeat"] = repeat
                roi_rows.append(row)
                observations.append(row)
            elif tag == "prepared_session_case":
                row = parse(cells, CASE_FIELDS, CASE_INTS)
                index = len(case_rows)
                if index >= 2 or len(roi_rows) != (index + 1) * packets * reuse:
                    raise ValueError("Missing/extra ROI data before phase")
                if (row["policy"] != policy or row["phase"] != PHASES[index]
                    or row["roi_side"] != side or row["reuse"] != reuse
                    or row["packets"] != packets
                    or row["roi_maps"] != packets * reuse
                    or row["preparations"] != (packets if policy == "reprepare" else 1)
                    or row["hot_gc_bytes"] != 0
                    or row["elapsed_ns"] <= 0):
                    raise ValueError("Incorrect session timing/preparation/GC contract")
                row["repeat"] = repeat
                case_rows.append(row)
                timings.append(row)
        if header_roi != 1 or header_case != 1:
            raise ValueError("Incorrect header count")
        if len(roi_rows) != 2 * packets * reuse or len(case_rows) != 2:
            raise ValueError("Incomplete phase/ROI transcript")
        process_summaries.append({
            "repeat": repeat, "policy": policy, "roi_side": side,
            "reuse": reuse, "packets_per_phase": packets,
            "roi_records": len(roi_rows),
            "total_ns": sum(x["elapsed_ns"] for x in case_rows),
            "hot_gc_bytes": sum(x["hot_gc_bytes"] for x in case_rows),
            "preparations": sum(x["preparations"] for x in case_rows)
        })
    return observations, timings, process_summaries, {
        "schema": "imagery-d-m3.2.20-scoped-prepared-session-v1",
        "processes": len(process_summaries),
        "phases": len(timings),
        "observed_roi_records": len(observations),
        "six_independent_samples_per_roi": len(observations) * 6,
        "source_independent_pixel_oracle": "PASS",
        "hot_gc_allocation_bytes": 0,
        "contract": "single scoped call vs repeated calls; no escaped Prepared token",
        "limitations": [
            "Real source and immutable metadata snapshots built outside timed phases",
            "First/last 3-channel ROI pixels; only final ROI all pixels",
            "Selected phase elapsed time, not whole process wall time",
            "No proof of reusable Prepared token across separate public calls",
            "Separate process groups, not within-process matched trials",
            "No hard real-time latency guarantee"
        ]
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("folder", type=Path)
    folder = p.parse_args().folder
    observations, timings, processes, summary = audit(folder)
    for name, rows in (
        ("prepared-session-rois.csv", observations),
        ("prepared-session-phases.csv", timings),
        ("prepared-session-processes.csv", processes)
    ):
        with (folder / name).open("w", newline="") as out:
            w = csv.DictWriter(out, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
    (folder / "prepared-session-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n")
    print("M3.2.20 QUALIFIED:", summary["processes"], "processes,",
          summary["observed_roi_records"], "individual ROIs,",
          summary["six_independent_samples_per_roi"], "physical pixels")


if __name__ == "__main__":
    main()
