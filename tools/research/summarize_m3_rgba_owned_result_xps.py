#!/usr/bin/env python3
"""Validate pinned owned RGBA XPS evidence and report paired round medians.

One row per independently launched case. Do not pool rounds across processes,
divide unrelated stage medians, or call these release-qualified timings.
"""
import csv
import hashlib
import statistics
import sys
from pathlib import Path

HEADER = (
    "pattern", "layout", "roi", "width", "height", "pixels",
    "round", "iterations", "stage", "elapsed_us",
    "thread_gc_bytes", "canonical_checksum",
)
STAGES = (
    "prepared_reused_output",
    "owned_allocating_result",
    "buffered_allocating_final",
)
PAIRS = (
    ("owned_vs_prepared", "owned_allocating_result", "prepared_reused_output"),
    ("buffered_vs_prepared", "buffered_allocating_final",
     "prepared_reused_output"),
    ("buffered_vs_owned", "buffered_allocating_final",
     "owned_allocating_result"),
)
OUTPUT = (
    "pattern", "layout", "roi", "width", "height",
    "pixels", "rounds", "iterations", "prepared_ns_px",
    "owned_ns_px", "buffered_ns_px", "owned_prepared_ratio",
    "buffered_prepared_ratio", "buffered_owned_ratio",
    "buffered_owned_min", "buffered_owned_max",
    "gc_total_prepared", "gc_total_owned", "gc_total_buffered",
    "prepared_init_us",
)


def require(condition, msg):
    if not condition:
        raise ValueError(msg)


def summarize(directory: Path):
    env = {}
    for line in (directory / "environment.txt").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    mode = env.get("mode")
    require(mode in ("smoke", "micro"), "invalid owned benchmark mode")
    require(env.get("source_mode") == "pinned-v0.2.0",
            "benchmark must use released pinned dependencies")
    require(env.get("imagery_measured_commit"),
            "missing measured imagery source commit")
    is_smoke = mode == "smoke"
    width = 192 if is_smoke else 512
    height = width
    rounds = 2 if is_smoke else 7
    iterations = 2 if is_smoke else 24
    patterns = ("mixed",) if is_smoke else ("mixed", "transparent")
    sides = (16, 64) if is_smoke else (16, 32, 64, 128, 256)
    cases = {(p, l, s) for p in patterns
             for l in ("interleaved", "planar") for s in sides}

    manifest = {}
    for line in (directory / "CHECKSUMS.sha256").read_text().splitlines():
        fields = line.split(maxsplit=1)
        require(len(fields) == 2, "malformed SHA-256 manifest row")
        digest, filename = fields
        name = filename.removeprefix("*").removeprefix("./")
        require(name.endswith(".csv") and "/" not in name,
                "unexpected checksum manifest path")
        require(name not in manifest, "duplicate checksum manifest entry")
        manifest[name] = digest
    expected_names = {
        f"{width}x{height}-{pattern}-{layout}-square{side}.csv"
        for pattern, layout, side in cases
    }
    require(set(manifest) == expected_names,
            "manifest cases do not match declared benchmark matrix")
    # The shell opens its redirected output *before* this validator starts.
    # OWNED_COMPARISON.csv is derived data, never a raw benchmark case or a
    # member of CHECKSUMS.sha256. Reject every other unexpected CSV.
    observed_raw = {
        path.name for path in directory.glob("*.csv")
        if path.name != "OWNED_COMPARISON.csv"
    }
    require(observed_raw == expected_names,
            "unexpected/missing raw CSV files (derived CSV excluded)")

    output = []
    across_layout_checksum = {}
    for pattern, layout, side in sorted(cases):
        filename = f"{width}x{height}-{pattern}-{layout}-square{side}.csv"
        raw = (directory / filename).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == manifest[filename],
                "SHA-256 mismatch: " + filename)
        lines = list(csv.reader(raw.decode("utf-8").splitlines()))
        require(lines and tuple(lines[0]) == HEADER,
                "CSV header mismatch: " + filename)
        require(len(lines) == 2 + rounds * len(STAGES),
                "missing/duplicate stage rows: " + filename)
        trailer = ",".join(lines[-1])
        require(trailer.startswith("OWNED-BENCH PASS:") and
                "prepared_init_us=" in trailer,
                "missing/malformed PASS marker: " + filename)
        tail = trailer.split("prepared_init_us=")[-1].strip()
        require(tail.isdigit(), "bad prepared init time: " + filename)

        measurements = {}
        stage_gc = {stage: 0 for stage in STAGES}
        checksums = set()
        for fields in lines[1:-1]:
            require(len(fields) == len(HEADER), "malformed stage CSV record")
            row = dict(zip(HEADER, fields))
            require(row["pattern"] == pattern and row["layout"] == layout and
                    row["roi"] == f"square{side}",
                    "case classification mismatch")
            require(int(row["width"]) == width and
                    int(row["height"]) == height and
                    int(row["pixels"]) == side * side and
                    int(row["iterations"]) == iterations,
                    "case dimensions/iterations mismatch")
            round_index = int(row["round"])
            require(0 <= round_index < rounds, "round outside expected set")
            stage = row["stage"]
            require(stage in STAGES, "unknown stage")
            micros = int(row["elapsed_us"])
            gc = int(row["thread_gc_bytes"])
            require(micros > 0 and gc >= 0, "invalid timing or GC delta")
            key = (round_index, stage)
            require(key not in measurements, "duplicate round/stage")
            measurements[key] = micros
            stage_gc[stage] += gc
            checksums.add(int(row["canonical_checksum"]))
        require(len(measurements) == rounds * len(STAGES) and
                len(checksums) == 1,
                "incomplete stage/round matrix or checksum disagreement")
        c = next(iter(checksums))
        cross = (pattern, side)
        if cross in across_layout_checksum:
            require(across_layout_checksum[cross] == c,
                    "canonical result differs between source layouts")
        else:
            across_layout_checksum[cross] = c

        def ns_px(stage):
            return statistics.median(
                measurements[(i, stage)] * 1000 /
                (iterations * side * side) for i in range(rounds))

        ratios = {}
        extrema = {}
        for name, numerator, denominator in PAIRS:
            values = [
                measurements[(i, numerator)] /
                measurements[(i, denominator)]
                for i in range(rounds)
            ]
            ratios[name] = statistics.median(values)
            extrema[name] = (min(values), max(values))
        output.append((
            pattern, layout, f"square{side}", width, height, side*side,
            rounds, iterations,
            f"{ns_px(STAGES[0]):.6f}", f"{ns_px(STAGES[1]):.6f}",
            f"{ns_px(STAGES[2]):.6f}",
            f"{ratios['owned_vs_prepared']:.6f}",
            f"{ratios['buffered_vs_prepared']:.6f}",
            f"{ratios['buffered_vs_owned']:.6f}",
            f"{extrema['buffered_vs_owned'][0]:.6f}",
            f"{extrema['buffered_vs_owned'][1]:.6f}",
            stage_gc[STAGES[0]], stage_gc[STAGES[1]],
            stage_gc[STAGES[2]], int(tail),
        ))
    require(len(output) == len(cases), "incomplete comparison matrix")
    return output


def main(directory: Path):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(OUTPUT)
    writer.writerows(summarize(directory))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_m3_rgba_owned_result_xps.py OUT")
    main(Path(sys.argv[1]))
