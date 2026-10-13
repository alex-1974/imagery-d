#!/usr/bin/env python3
"""Validate native paired 10-stage micro-ROI evidence, preserving case grouping.

Only describe one XPS session; rounds within a process are correlated.
Called after checksum generation; outputs a *derived* CSV (not in the raw manifest).
"""
import csv
import hashlib
import statistics
import sys
from pathlib import Path

STAGES = {
    "checked_io", "decode_2rgb", "premultiply_2", "source_over",
    "unpremul_encode_quantize", "packed_full", "fourplane_full",
    "prepared_fourplane_full", "buffered_packed_commit",
    "buffered_allocating_commit",
}
HEADER = (
    "pattern", "layout", "roi", "width", "height", "pixels", "round",
    "iterations", "stage", "elapsed_us", "thread_gc_bytes",
    "canonical_checksum",
)
PAIRS = (
    ("direct_prepared", "fourplane_full", "prepared_fourplane_full"),
    ("prepared_reused", "buffered_packed_commit",
        "prepared_fourplane_full"),
    ("prepared_alloc", "buffered_allocating_commit",
        "prepared_fourplane_full"),
    ("alloc_reused", "buffered_allocating_commit",
        "buffered_packed_commit"),
)

def require(value, explanation):
    if not value:
        raise ValueError(explanation)

def main(directory: Path):
    env = {}
    for line in (directory / "environment.txt").read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if k in ("mode", "source_mode", "smoke"):
                env[k] = v
    mode = env.get("mode")
    require(mode in ("micro", "micro_smoke"), "not a micro-ROI run")
    require(env.get("source_mode") == "pinned-v0.2.0",
            "dependencies must be pinned v0.2.0")
    smoke = mode == "micro_smoke"
    backing = (192, 192) if smoke else (512, 512)
    iterations = 2 if smoke else 24
    rounds = 2 if smoke else 7
    patterns = ("mixed",) if smoke else ("mixed", "transparent")
    sides = (16, 64) if smoke else (16, 32, 64, 128)
    expected_cases = {
        (pattern, layout, side)
        for pattern in patterns for layout in ("planar", "interleaved")
        for side in sides
    }
    manifest = {}
    for line in (directory / "CHECKSUMS.sha256").read_text().splitlines():
        checksum, filename = line.split(maxsplit=1)
        name = filename.removeprefix("*").removeprefix("./")
        require(name not in manifest, "duplicate manifest entry " + name)
        manifest[name] = checksum
    require(len(manifest) == len(expected_cases),
            "wrong number of manifest files")
    observed = set()
    output_hashes = {}
    summaries = []
    for filename, digest in sorted(manifest.items()):
        require(filename.endswith(".csv") and
                filename not in ("STAGE_SUMMARY.csv", "MICRO_COMPARISON.csv"),
                "manifest contains nonraw case")
        path = directory / filename
        require(path.is_file(), "missing raw CSV " + filename)
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                "checksum mismatch " + filename)
        with path.open(newline="", encoding="utf8") as fp:
            contents = list(csv.reader(fp))
        require(len(contents) == 2 + rounds * len(STAGES),
                "wrong number of records " + filename)
        require(tuple(contents[0]) == HEADER, "incorrect header " + filename)
        require(len(contents[-1]) == 1 and
                contents[-1][0].startswith("HOTPATH-STAGES PASS:"),
                "missing PASS marker " + filename)
        require(all(len(row) == len(HEADER) for row in contents[1:-1]),
                "malformed data " + filename)
        rows = [dict(zip(HEADER, row)) for row in contents[1:-1]]
        x = rows[0]
        require(x["roi"].startswith("square") and x["roi"][6:].isdigit(),
                "expected offset square ROI")
        side = int(x["roi"][6:])
        case = (x["pattern"], x["layout"], side)
        require(case in expected_cases and case not in observed,
                "unrecognized/duplicated scenario " + str(case))
        observed.add(case)
        groups = {}
        canonical = x["canonical_checksum"]
        for row in rows:
            require((row["pattern"], row["layout"], row["roi"]) ==
                    (x["pattern"], x["layout"], x["roi"]),
                    "case mutated inside rounds")
            require((int(row["width"]), int(row["height"])) == backing,
                    "wrong backing dimensions")
            require(int(row["pixels"]) == side * side,
                    "wrong ROI pixel count")
            require(int(row["iterations"]) == iterations,
                    "wrong iterations")
            require(int(row["thread_gc_bytes"]) == 0,
                    "GC increase in timed call")
            require(row["canonical_checksum"] == canonical,
                    "changing result checksum")
            name = row["stage"]
            round_id = int(row["round"])
            require(name in STAGES and 0 <= round_id < rounds,
                    "unexpected stage or round")
            key = (round_id, name)
            require(key not in groups, "duplicated stage/round")
            elapsed = int(row["elapsed_us"])
            require(elapsed >= 0, "negative timed microseconds")
            if name in ("fourplane_full", "prepared_fourplane_full",
                        "buffered_packed_commit",
                        "buffered_allocating_commit"):
                require(elapsed > 0, "nonpositive paired full-path timing")
            groups[key] = elapsed
        require(len(groups) == rounds * len(STAGES),
                "missing stage/round")
        hash_key = (x["pattern"], side)
        require(hash_key not in output_hashes or
                output_hashes[hash_key] == canonical,
                "layout changed canonical output bytes")
        output_hashes[hash_key] = canonical
        per_stage = {name: [groups[(round_id, name)]
                  for round_id in range(rounds)] for name in STAGES}
        entry = {
            "pattern": x["pattern"], "layout": x["layout"],
            "roi_side": side, "pixels": side * side,
            "rounds": rounds, "iterations": iterations,
            "canonical_checksum": canonical,
        }
        for prefix, name in [
            ("direct", "fourplane_full"),
            ("prepared", "prepared_fourplane_full"),
            ("reused", "buffered_packed_commit"),
            ("allocating", "buffered_allocating_commit"),
        ]:
            entry[prefix + "_median_ns_per_pixel"] = "%.3f" % (
                statistics.median(per_stage[name]) * 1000 /
                (side * side * iterations))
        for label, numerator, denominator in PAIRS:
            fractions = [groups[(i, numerator)] / groups[(i, denominator)]
                         for i in range(rounds)]
            entry[label + "_median"] = "%.5f" % statistics.median(fractions)
            entry[label + "_min"] = "%.5f" % min(fractions)
            entry[label + "_max"] = "%.5f" % max(fractions)
        summaries.append(entry)
    require(observed == expected_cases,
            "missing expected scenarios " + str(expected_cases - observed))
    fields = [
        "pattern", "layout", "roi_side", "pixels", "rounds", "iterations",
        "canonical_checksum", "direct_median_ns_per_pixel",
        "prepared_median_ns_per_pixel", "reused_median_ns_per_pixel",
        "allocating_median_ns_per_pixel",
    ]
    for key, _, _ in PAIRS:
        fields.extend((key + "_median", key + "_min", key + "_max"))
    writer = csv.DictWriter(sys.stdout, fieldnames=fields,
                            lineterminator="\n")
    writer.writeheader()
    writer.writerows(sorted(summaries, key=lambda x: (
        x["roi_side"], x["pattern"], x["layout"])))
    print(f"MICRO BUFFERED VALIDATED: {len(summaries)} independent cases, "
          f"{len(summaries) * rounds} paired rounds, pinned sources, "
          "checksums and zero GC delta", file=sys.stderr)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_m3_rgba_buffered_micro.py OUT")
    main(Path(sys.argv[1]))
