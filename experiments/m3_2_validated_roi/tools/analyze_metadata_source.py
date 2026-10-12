#!/usr/bin/env python3
"""M3.2.18 strict, order-sensitive source-session physical pixel oracle.

Independently reconstruct *each* ROI's position and three lanes of both
its first and last calibrated pixel, not an order-insensitive aggregate.
"""
import argparse
import csv
import json
import math
import re
from pathlib import Path

POLICIES = ("immutable", "snapshot")
PHASES = ("original", "refreshed")
ROI_FIELDS = (
    "policy", "phase", "packet", "roi", "roi_side", "reuse", "x", "y",
    "first0", "first1", "first2", "last0", "last1", "last2",
)
PACKET_FIELDS = (
    "policy", "phase", "packet", "roi_side", "reuse", "elapsed_ns",
    "hot_gc_bytes",
)
ROI_INT = ("packet", "roi", "roi_side", "reuse", "x", "y")
ROI_FLOAT = ("first0", "first1", "first2", "last0", "last1", "last2")
PK_INT = ("packet", "roi_side", "reuse", "elapsed_ns", "hot_gc_bytes")
LOG_RE = re.compile(
    r"run-(0|[1-9][0-9]*)-(immutable|snapshot)-(8|32)-(4|16)\.log\Z"
)
CFG_RE = re.compile(
    r"^repeats=(\d+) packets=(\d+) sides=([0-9,]+) reuses=([0-9,]+)$",
    re.M,
)
XS = (0, 3, 13, 29)
YS = (0, 7, 17, 23)
CHANNELS = (254, 253, 255)


def settings(folder):
    env = (folder / "environment.txt").read_text(encoding="utf-8")
    if "schema=imagery-d-m3.2.18-metadata-source-ordered-v1" not in env:
        raise ValueError("Invalid evidence schema")
    matches = CFG_RE.findall(env)
    if len(matches) != 1:
        raise ValueError("Missing/ambiguous run dimensions")
    repeats, packets = map(int, matches[0][:2])
    sides = tuple(map(int, matches[0][2].split(",")))
    reuses = tuple(map(int, matches[0][3].split(",")))
    if (repeats < 2 or not 1 <= packets <= 8192
            or not sides or len(set(sides)) != len(sides)
            or set(sides) - {8, 32}
            or not reuses or len(set(reuses)) != len(reuses)
            or set(reuses) - {4, 16}):
        raise ValueError("Invalid run dimensions")
    return repeats, packets, sides, reuses


def physical(phase, component, x, y):
    if (x + y) % 11 == 0:
        return 0.0
    choice = 2 if phase == "original" else 3
    scale = 0.5 + choice * 0.0625
    offset = -4 - choice
    return (CHANNELS[component] * 16 + 2 * y + x) * scale + offset


def parse_row(cells, fieldnames, ints, floats=()):
    if len(cells) != len(fieldnames) + 1:
        raise ValueError("Incorrect record width")
    row = dict(zip(fieldnames, cells[1:]))
    try:
        for f in ints:
            row[f] = int(row[f])
        for f in floats:
            row[f] = float(row[f])
    except (ValueError, OverflowError) as exc:
        raise ValueError("Non-numeric source evidence") from exc
    return row


def audit(folder):
    repeats, packets, sides, reuses = settings(folder)
    expected_keys = {
        (run, policy, side, reuse)
        for run in range(repeats)
        for policy in POLICIES
        for side in sides
        for reuse in reuses
    }
    found = {}
    for f in folder.glob("run-*.log"):
        m = LOG_RE.fullmatch(f.name)
        if not m:
            raise ValueError("Invalid source-process log filename")
        key = (int(m[1]), m[2], int(m[3]), int(m[4]))
        if key in found:
            raise ValueError("Duplicate source process")
        found[key] = f
    if set(found) != expected_keys:
        raise ValueError("Missing/extra source processes")

    rois, packet_rows, process_rows = [], [], []
    for (run, policy, side, reuse), path in sorted(found.items()):
        text = path.read_text(encoding="utf-8")
        marker = ("M3.2.18 PASS: immutable source lifetime "
                  "and all ordered ROI lanes")
        if text.count(marker) != 1:
            raise ValueError("Missing/duplicate D lifetime/full-pixel PASS")
        seen_headers = set()
        measured = []
        roi_log = []
        for cells in csv.reader(text.splitlines()):
            if not cells:
                continue
            tag = cells[0]
            if tag == "metadata_source_roi_schema":
                if tag in seen_headers or cells[1:] != list(ROI_FIELDS):
                    raise ValueError("Unexpected ordered ROI schema")
                seen_headers.add(tag)
            elif tag == "metadata_source_packet_schema":
                if tag in seen_headers or cells[1:] != list(PACKET_FIELDS):
                    raise ValueError("Unexpected packet schema")
                seen_headers.add(tag)
            elif tag == "metadata_source_roi":
                row = parse_row(cells, ROI_FIELDS, ROI_INT, ROI_FLOAT)
                index = len(roi_log)
                expected_phase = PHASES[index // (packets * reuse)]                     if index < len(PHASES) * packets * reuse else None
                expected_packet = (index // reuse) % packets
                expected_roi = index % reuse
                k = (expected_packet + expected_roi) % 4
                if (row["policy"] != policy
                    or row["phase"] != expected_phase
                    or row["packet"] != expected_packet
                    or row["roi"] != expected_roi
                    or row["roi_side"] != side or row["reuse"] != reuse
                    or row["x"] != XS[k] or row["y"] != YS[k]):
                    raise ValueError("Reordered/missing/wrong ROI coordinate")
                for component in range(3):
                    for name, x, y in (
                        ("first", XS[k], YS[k]),
                        ("last", XS[k] + side - 1, YS[k] + side - 1),
                    ):
                        actual = row[f"{name}{component}"]
                        expected = physical(expected_phase, component, x, y)
                        if (not math.isfinite(actual)
                            or not math.isclose(actual, expected,
                                                rel_tol=0, abs_tol=0.011)):
                            raise ValueError("Forged/wrong ordered physical ROI pixel")
                row["run"] = run
                roi_log.append(row)
                rois.append(row)
            elif tag == "metadata_source_packet":
                row = parse_row(cells, PACKET_FIELDS, PK_INT)
                count = len(measured)
                phase = PHASES[count // packets] if count < 2 * packets else None
                expected_packet = count % packets
                if (row["policy"] != policy or row["phase"] != phase
                    or row["packet"] != expected_packet
                    or row["roi_side"] != side or row["reuse"] != reuse
                    or row["elapsed_ns"] <= 0 or row["hot_gc_bytes"] != 0
                    or len(roi_log) != (count + 1) * reuse):
                    raise ValueError("Wrong packet count/order or @nogc contract")
                row["run"] = run
                measured.append(row)
                packet_rows.append(row)
        if seen_headers != {"metadata_source_roi_schema",
                            "metadata_source_packet_schema"}:
            raise ValueError("Missing source transcript headers")
        if len(measured) != 2 * packets or len(roi_log) != 2 * packets * reuse:
            raise ValueError("Incomplete ROI/packet transcript")
        original = roi_log[:packets * reuse]
        refreshed = roi_log[packets * reuse:]
        if not any(x["first1"] != y["first1"] or x["last1"] != y["last1"]
                   for x, y in zip(original, refreshed)):
            raise ValueError("Refresh was not observable")
        process_rows.append({
            "run": run, "policy": policy, "roi_side": side, "reuse": reuse,
            "packets_per_phase": packets, "phases": len(PHASES),
            "roi_rows": len(roi_log),
            "hot_gc_bytes": sum(q["hot_gc_bytes"] for q in measured),
            "measured_packet_time_ns": sum(q["elapsed_ns"] for q in measured),
            "max_packet_time_ns": max(q["elapsed_ns"] for q in measured),
        })
    return rois, packet_rows, process_rows, {
        "schema": "imagery-d-m3.2.18-metadata-source-ordered-v1",
        "processes": len(process_rows),
        "packets": len(packet_rows),
        "ordered_roi_records": len(rois),
        "independent_per_roi_six_pixel_oracle": "PASS",
        "mutable_alias_snapshot_and_refresh": "PASS",
        "per_packet_gc_allocation_bytes": 0,
        "limitation": ("This probe revalidates/prepares at each packet, but borrows "
                       "the unchanged immutable source arrays. It is a correctness "
                       "and allocation probe, not a cross-policy performance verdict. "
                       "Pixels are validated at two corners per ROI externally, plus "
                       "the D full-pixel last-ROI oracle. Original immutable fixture "
                       "construction is not a zero-allocation lifetime claim."),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("folder", type=Path)
    folder = p.parse_args().folder
    rois, packets, processes, result = audit(folder)
    for name, rows in (("metadata-source-rois.csv", rois),
                       ("metadata-source-packets.csv", packets),
                       ("metadata-source-processes.csv", processes)):
        with (folder / name).open("w", newline="") as output:
            w = csv.DictWriter(output, list(rows[0]))
            w.writeheader()
            w.writerows(rows)
    (folder / "metadata-source-summary.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {result['processes']} isolated sources, "
          f"{result['packets']} packets, "
          f"{result['ordered_roi_records']} separately checked ROIs")


if __name__ == "__main__":
    main()
