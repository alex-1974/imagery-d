#!/usr/bin/env python3
"""Validate and summarize paired small-ROI direct-vs-LUT raster zip evidence.

Research-only: do not interpret correlated rounds as independent OS processes.
"""
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

HEADER = (
    "pattern", "layout", "roi", "width", "height", "pixels", "round",
    "iterations", "direct_zip_us", "lut_zip_us", "thread_gc_bytes",
    "output_checksum", "pixel_differences", "lut_init_us",
)

def need(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)

def process(folder: Path) -> None:
    settings = {}
    for line in (folder / "environment.txt").read_text(encoding="utf8").splitlines():
        if "=" in line:
            k, value = line.split("=", 1)
            if k in ("mode", "smoke", "source_mode"):
                settings[k] = value
    mode = settings.get("mode")
    need(mode in ("micro", "micro_smoke"), "not a micro-ROI archive")
    need(settings.get("source_mode") == "pinned-v0.2.0",
         "not pinned to v0.2.0")
    expected_patterns = ("mixed", "transparent") if mode == "micro" else ("mixed",)
    expected_sizes = (16, 32, 64, 128) if mode == "micro" else (16, 32)
    expected_shape = (512, 512) if mode == "micro" else (96, 96)
    expected_rounds = 9 if mode == "micro" else 2
    expected_iterations = 32 if mode == "micro" else 3
    expected = {
        (p, layout, side)
        for p in expected_patterns
        for layout in ("compact", "padded")
        for side in expected_sizes
    }
    sources = sorted(folder.glob("*.csv"))
    observed = set()
    hashes = {}
    summary = []
    for file in sources:
        if file.name == "MICRO_SUMMARY.csv":
            continue
        with file.open(newline="", encoding="utf8") as stream:
            rows = list(csv.reader(stream))
        need(len(rows) == expected_rounds + 2, f"{file.name}: wrong row count")
        need(tuple(rows[0]) == HEADER, f"{file.name}: unexpected schema")
        need(len(rows[-1]) == 1 and rows[-1][0].startswith("ZIP-EXACT-LUT PASS:"),
             f"{file.name}: missing PASS marker")
        events = [dict(zip(HEADER, row)) for row in rows[1:-1]]
        need(all(len(row) == len(HEADER) for row in rows[1:-1]),
             f"{file.name}: malformed row")
        name = events[0]
        need(name["roi"].startswith("square") and name["roi"][6:].isdigit(),
             f"{file.name}: not an offset square ROI")
        side = int(name["roi"][6:])
        case = (name["pattern"], name["layout"], side)
        need(case in expected and case not in observed,
             f"{file.name}: unexpected/duplicate case {case}")
        observed.add(case)
        pixels = side * side
        ratios = []
        direct_samples = []
        lut_samples = []
        init_samples = []
        round_ids = []
        for row in events:
            need((row["pattern"], row["layout"], row["roi"]) ==
                 (name["pattern"], name["layout"], name["roi"]),
                 f"{file.name}: inconsistent case")
            need((int(row["width"]), int(row["height"])) == expected_shape,
                 f"{file.name}: wrong backing dimensions")
            need(int(row["pixels"]) == pixels,
                 f"{file.name}: wrong ROI pixel count")
            need(int(row["iterations"]) == expected_iterations,
                 f"{file.name}: wrong iteration count")
            need(int(row["thread_gc_bytes"]) == 0 and
                 int(row["pixel_differences"]) == 0,
                 f"{file.name}: GC or pixel difference")
            direct = int(row["direct_zip_us"])
            lut = int(row["lut_zip_us"])
            need(direct > 0 and lut > 0, f"{file.name}: nonpositive timing")
            direct_samples.append(direct)
            lut_samples.append(lut)
            ratios.append(direct / lut)
            init_samples.append(int(row["lut_init_us"]))
            round_ids.append(int(row["round"]))
            need(row["output_checksum"] == name["output_checksum"],
                 f"{file.name}: varying checksum")
        need(sorted(round_ids) == list(range(expected_rounds)),
             f"{file.name}: incomplete/duplicate round indices")
        key = (name["pattern"], side)
        if key in hashes:
            need(hashes[key] == name["output_checksum"],
                 f"{file.name}: layout changed output checksum")
        hashes[key] = name["output_checksum"]
        summary.append({
            "pattern": name["pattern"],
            "layout": name["layout"],
            "roi_side": side,
            "backing_width": expected_shape[0],
            "backing_height": expected_shape[1],
            "pixels": pixels,
            "rounds": expected_rounds,
            "iterations": expected_iterations,
            "direct_median_ns_per_pixel":
                f"{statistics.median(direct_samples)*1000/(pixels*expected_iterations):.3f}",
            "lut_median_ns_per_pixel":
                f"{statistics.median(lut_samples)*1000/(pixels*expected_iterations):.3f}",
            "paired_ratio_median": f"{statistics.median(ratios):.4f}",
            "paired_ratio_min": f"{min(ratios):.4f}",
            "paired_ratio_max": f"{max(ratios):.4f}",
            "lut_init_median_us": f"{statistics.median(init_samples):.3f}",
            "output_checksum": name["output_checksum"],
        })
    need(observed == expected,
         f"missing/extra scenarios: missing={expected-observed}")
    writer = csv.DictWriter(sys.stdout, fieldnames=list(summary[0]),
                            lineterminator="\n")
    writer.writeheader()
    writer.writerows(sorted(summary, key=lambda x: (
        x["roi_side"], x["pattern"], x["layout"])))
    print(f"VALIDATED {len(summary)} pinned ROI scenarios; {len(summary)*expected_rounds} "
          "paired rounds; all pixels/checksums/GC valid", file=sys.stderr)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_m3_rgba_lut_zip_micro.py results-directory")
    process(Path(sys.argv[1]))
