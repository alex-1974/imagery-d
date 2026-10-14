#!/usr/bin/env python3
"""Validate and summarize Issue #74 consumer-shaped paired delivery evidence.

Do not use raw GitHub CI timings as XPS results. Full native provenance,
compiler and governor evidence live in the accompanying pinned-runner archive.
"""
import csv
import io
import statistics
import sys
from pathlib import Path

HEADER = ("experiment,side,round,stage,iterations,elapsed_us,"
          "thread_gc_bytes,digest")
FAMILIES = {
    "hot": ("hot_raw_two_subscribers", "hot_controlled_two_subscribers"),
    "churn": ("roi_raw_evicted", "roi_controlled_evicted"),
}
STAGES = {stage for pair in FAMILIES.values() for stage in pair}


def summarize(raw_text: str) -> str:
    lines = raw_text.splitlines()
    if lines.count(HEADER) != 1:
        raise ValueError("expected exactly one CSV header")
    if sum(x.startswith("DELIVERY-WORKFLOW PASS:") for x in lines) != 1:
        raise ValueError("missing or repeated success trailer")
    records = [x for x in lines if x.startswith("m3_delivery_workflow,")]
    if not records:
        raise ValueError("missing timed workflow measurements")
    parsed = list(csv.DictReader(io.StringIO(HEADER + "\n" +
                                              "\n".join(records))))
    groups: dict[tuple[int, int], dict[str, tuple[int, int, int, int]]] = {}
    for row in parsed:
        try:
            side = int(row["side"])
            round_number = int(row["round"])
            stage = row["stage"]
            iterations = int(row["iterations"])
            elapsed = int(row["elapsed_us"])
            gc_bytes = int(row["thread_gc_bytes"])
            digest = int(row["digest"])
        except (ValueError, TypeError, KeyError) as exc:
            raise ValueError("unparseable stage row") from exc
        if (row["experiment"] != "m3_delivery_workflow" or
                side not in (16, 64) or round_number < 0 or
                stage not in STAGES or iterations <= 0 or
                elapsed <= 0 or gc_bytes < 0 or digest <= 0):
            raise ValueError("invalid workflow row semantics")
        group = groups.setdefault((side, round_number), {})
        if stage in group:
            raise ValueError("duplicate stage in one side/round")
        group[stage] = (iterations, elapsed, gc_bytes, digest)
    if not groups:
        raise ValueError("no complete groups")
    sides = sorted({side for side, _ in groups})
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow([
        "record", "side", "family", "round",
        "raw_ns_per_cycle", "controlled_ns_per_cycle",
        "controlled_minus_raw_ns", "controlled_over_raw_ratio",
        "raw_gc_bytes", "controlled_gc_bytes",
    ])
    for side in sides:
        found = sorted(number for s, number in groups if s == side)
        if found != list(range(len(found))):
            raise ValueError("missing/noncontiguous rounds for side")
        values = {name: ([], [], [], []) for name in FAMILIES}
        for number in found:
            group = groups[(side, number)]
            if set(group) != STAGES:
                raise ValueError("missing or unexpected stage in round")
            for name, (raw_name, controlled_name) in FAMILIES.items():
                raw_count, raw_us, raw_gc, raw_digest = group[raw_name]
                ctrl_count, ctrl_us, ctrl_gc, ctrl_digest = group[controlled_name]
                if raw_count != ctrl_count or raw_digest != ctrl_digest:
                    raise ValueError("mismatched work or pixel digest")
                raw_ns = raw_us * 1000 / raw_count
                controlled_ns = ctrl_us * 1000 / ctrl_count
                delta = controlled_ns - raw_ns
                ratio = controlled_ns / raw_ns
                values[name][0].append(raw_ns)
                values[name][1].append(controlled_ns)
                values[name][2].append(delta)
                values[name][3].append(ratio)
                writer.writerow([
                    "round", side, name, number,
                    f"{raw_ns:.6f}", f"{controlled_ns:.6f}",
                    f"{delta:.6f}", f"{ratio:.6f}", raw_gc, ctrl_gc,
                ])
        for name, (raws, controlled, deltas, ratios) in values.items():
            writer.writerow([
                "median", side, name, len(found),
                f"{statistics.median(raws):.6f}",
                f"{statistics.median(controlled):.6f}",
                f"{statistics.median(deltas):.6f}",
                f"{statistics.median(ratios):.6f}", "", "",
            ])
    return out.getvalue()


def self_test() -> None:
    lines = [
        HEADER,
        "m3_delivery_workflow,16,0,hot_raw_two_subscribers,1000,40,0,100",
        "m3_delivery_workflow,16,0,hot_controlled_two_subscribers,1000,50,0,100",
        "m3_delivery_workflow,16,0,roi_raw_evicted,10,200,0,55",
        "m3_delivery_workflow,16,0,roi_controlled_evicted,10,250,128,55",
        "m3_delivery_workflow,16,1,hot_controlled_two_subscribers,1000,60,0,100",
        "m3_delivery_workflow,16,1,hot_raw_two_subscribers,1000,40,0,100",
        "m3_delivery_workflow,16,1,roi_controlled_evicted,10,240,128,55",
        "m3_delivery_workflow,16,1,roi_raw_evicted,10,200,0,55",
        "DELIVERY-WORKFLOW PASS: fixture",
    ]
    src = "\n".join(lines) + "\n"
    result = summarize(src)
    assert "round,16,hot,0,40.000000,50.000000,10.000000" in result
    assert "median,16,hot,2,40.000000,55.000000" in result
    assert "median,16,churn,2,20000.000000,24500.000000" in result
    invalids = [
        src.replace(lines[8] + "\n", ""),
        src.replace("1000,50,0,100", "1000,50,0,99"),
        src.replace("1000,50,0,100", "900,50,0,100"),
        src.replace("DELIVERY-WORKFLOW PASS: fixture\n", ""),
    ]
    for bad in invalids:
        try:
            summarize(bad)
        except ValueError:
            continue
        raise AssertionError("invalid benchmark workflow accepted")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        print("DELIVERY-WORKFLOW SUMMARY SELF-TEST PASS")
    elif len(sys.argv) == 2:
        try:
            print(summarize(Path(sys.argv[1]).read_text()), end="")
        except (OSError, ValueError) as error:
            sys.exit(f"invalid delivery workflow evidence: {error}")
    else:
        sys.exit("Usage: summarize_m3_rgba_delivery_workflow_xps.py [--self-test|raw-runner.txt]")
