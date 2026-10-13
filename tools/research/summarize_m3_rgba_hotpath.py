#!/usr/bin/env python3
"""Validate raw M3 hotpath runs and report per-stage *non-additive* timing."""
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

STAGES = {
    "checked_io",
    "decode_2rgb",
    "premultiply_2",
    "source_over",
    "unpremul_encode_quantize",
    "packed_full",
    "fourplane_full",
}
REQUIRED = {
    "pattern", "layout", "roi", "width", "height", "pixels",
    "round", "iterations", "stage", "elapsed_us", "thread_gc_bytes",
    "canonical_checksum",
}


def report(directory: Path) -> None:
    all_files = sorted(directory.glob("*.csv"))
    cases = [p for p in all_files if p.name not in ("STAGE_SUMMARY.csv",)]
    if not cases:
        raise ValueError(f"no case CSV files in {directory}")

    cross_layout = {}
    all_records = []
    for path in cases:
        with path.open(newline="", encoding="utf-8") as stream:
            raw = list(csv.reader(stream))
        if len(raw) < 3 or not raw[-1][0].startswith("HOTPATH-STAGES PASS:"):
            raise ValueError(f"{path}: missing PASS marker")
        header = raw[0]
        if set(header) != REQUIRED or len(header) != len(REQUIRED):
            raise ValueError(f"{path}: unexpected stage CSV schema")
        records = [dict(zip(header, line)) for line in raw[1:-1]]
        if any(len(line) != len(header) for line in raw[1:-1]):
            raise ValueError(f"{path}: malformed row")

        keys = {"pattern", "layout", "roi", "width", "height", "pixels",
                "iterations", "canonical_checksum"}
        for k in keys:
            if len({row[k] for row in records}) != 1:
                raise ValueError(f"{path}: inconsistent {k}")
        values = records[0]
        width = int(values["width"])
        height = int(values["height"])
        pixels = int(values["pixels"])
        iterations = int(values["iterations"])
        rounds = {int(row["round"]) for row in records}
        if not (pixels > 0 and width >= 24 and height >= 24 and
                pixels <= width * height and iterations > 0 and
                rounds == set(range(len(rounds))) and
                len(records) == len(rounds) * len(STAGES)):
            raise ValueError(f"{path}: invalid dimensions/round counts")

        observed = defaultdict(list)
        for row in records:
            name = row["stage"]
            if name not in STAGES:
                raise ValueError(f"{path}: unexpected stage {name}")
            if int(row["thread_gc_bytes"]) != 0:
                raise ValueError(f"{path}: nonzero stage GC bytes")
            elapsed_us = int(row["elapsed_us"])
            if elapsed_us < 0:
                raise ValueError(f"{path}: negative timing")
            observed[name].append((int(row["round"]), elapsed_us))
        if set(observed) != STAGES:
            raise ValueError(f"{path}: missing stage")
        for stage, observations in observed.items():
            if {r for r, _ in observations} != rounds:
                raise ValueError(f"{path}: stage {stage} incomplete/duplicate")
            times = [us for _, us in observations]
            all_records.append({
                "pattern": values["pattern"],
                "layout": values["layout"],
                "roi": values["roi"],
                "width": width,
                "height": height,
                "pixels": pixels,
                "rounds": len(rounds),
                "iterations": iterations,
                "stage": stage,
                "median_us": statistics.median(times),
                "min_us": min(times),
                "max_us": max(times),
                "median_ns_per_pixel": statistics.median(times) * 1000 /
                    (pixels * iterations),
                "canonical_checksum": values["canonical_checksum"],
            })
        identity = (
            values["pattern"], width, height, values["roi"]
        )
        if identity in cross_layout and cross_layout[identity] != values[
                "canonical_checksum"]:
            raise ValueError(f"{path}: output changed between raster layouts")
        cross_layout[identity] = values["canonical_checksum"]

    fields = [
        "pattern", "layout", "roi", "width", "height", "pixels",
        "rounds", "iterations", "stage", "median_us", "min_us",
        "max_us", "median_ns_per_pixel", "canonical_checksum"
    ]
    writer = csv.DictWriter(sys.stdout, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for record in sorted(all_records, key=lambda r: (
            r["width"], r["height"], r["pattern"],
            r["layout"], r["roi"], r["stage"])):
        record["median_ns_per_pixel"] = f"{record['median_ns_per_pixel']:.3f}"
        writer.writerow(record)

    print(
        f"VALIDATED {len(cases)} cases, {len(all_records)} stage medians; "
        "all complete, zero stage GC bytes, layout output checksums agree",
        file=sys.stderr,
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_m3_rgba_hotpath.py <results-directory>")
    report(Path(sys.argv[1]))
