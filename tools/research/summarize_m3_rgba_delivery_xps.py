#!/usr/bin/env python3
"""Summarize paired native delivery control-plane timing rows (no numpy).

Input is the raw consumer stdout, including the DELIVERY-METADATA header,
CSV stage records and DELIVERY-BENCH PASS trailer. Do not infer XPS provenance
from CSV alone: caller must verify environment and raw SHA-256 evidence.
"""
import csv
import io
import statistics
import sys
from pathlib import Path

HEADER = (
    "experiment,round,stage,iterations,elapsed_us,"
    "thread_gc_bytes,completed_pairs"
)
STAGES = {"raw_raster_lease", "owned_delivery_handle"}


def summarize(raw: str) -> str:
    lines = raw.splitlines()
    if lines.count(HEADER) != 1:
        raise ValueError("expected exactly one delivery CSV header")
    if sum(line.startswith("DELIVERY-BENCH PASS:") for line in lines) != 1:
        raise ValueError("missing or duplicate successful benchmark trailer")
    rows = [line for line in lines if line.startswith("m3_delivery,")]
    if not rows:
        raise ValueError("no delivery stage rows")
    parsed = list(csv.DictReader(io.StringIO(HEADER + "\n" + "\n".join(rows))))
    by_round: dict[int, dict[str, dict]] = {}
    for row in parsed:
        try:
            number = int(row["round"])
            count = int(row["iterations"])
            elapsed = int(row["elapsed_us"])
            gc_bytes = int(row["thread_gc_bytes"])
            stage = row["stage"]
            completed = int(row["completed_pairs"])
        except (ValueError, TypeError, KeyError) as exc:
            raise ValueError("invalid paired benchmark row") from exc
        if (row["experiment"] != "m3_delivery" or stage not in STAGES or
                number < 0 or count <= 0 or elapsed <= 0 or
                gc_bytes < 0 or completed <= 0):
            raise ValueError("malformed/nonpositive stage fields")
        stages = by_round.setdefault(number, {})
        if stage in stages:
            raise ValueError("duplicate benchmark stage")
        stages[stage] = {
            "iterations": count,
            "elapsed_us": elapsed,
            "gc": gc_bytes,
        }
    if sorted(by_round) != list(range(len(by_round))):
        raise ValueError("rounds are not contiguous from zero")

    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow([
        "record", "round", "raw_ns_per_pair", "delivery_ns_per_pair",
        "delivery_minus_raw_ns_per_pair", "delivery_over_raw_ratio",
        "raw_gc_bytes", "delivery_gc_bytes",
    ])
    raw_values, handle_values, differences, ratios = [], [], [], []
    for number in sorted(by_round):
        stages = by_round[number]
        if set(stages) != STAGES:
            raise ValueError("unpaired round")
        raw_stage, handle = (
            stages["raw_raster_lease"], stages["owned_delivery_handle"]
        )
        if raw_stage["iterations"] != handle["iterations"]:
            raise ValueError("mismatched work in paired round")
        count = raw_stage["iterations"]
        raw_ns = 1000 * raw_stage["elapsed_us"] / count
        handle_ns = 1000 * handle["elapsed_us"] / count
        delta = handle_ns - raw_ns
        ratio = handle_ns / raw_ns
        raw_values.append(raw_ns)
        handle_values.append(handle_ns)
        differences.append(delta)
        ratios.append(ratio)
        writer.writerow([
            "round", number, f"{raw_ns:.6f}", f"{handle_ns:.6f}",
            f"{delta:.6f}", f"{ratio:.6f}",
            raw_stage["gc"], handle["gc"],
        ])
    writer.writerow([
        "median", len(by_round),
        f"{statistics.median(raw_values):.6f}",
        f"{statistics.median(handle_values):.6f}",
        f"{statistics.median(differences):.6f}",
        f"{statistics.median(ratios):.6f}",
        "", "",
    ])
    return out.getvalue()


def self_test() -> None:
    sample = (
        "DELIVERY-METADATA research_cache_control_gc_thread_bytes=160\n"
        + HEADER + "\n"
        + "m3_delivery,0,raw_raster_lease,1000,10,0,1000\n"
        + "m3_delivery,0,owned_delivery_handle,1000,20,0,2000\n"
        + "m3_delivery,1,owned_delivery_handle,1000,24,0,3000\n"
        + "m3_delivery,1,raw_raster_lease,1000,12,0,4000\n"
        + "DELIVERY-BENCH PASS: test\n"
    )
    summary = summarize(sample)
    assert "round,0,10.000000,20.000000,10.000000,2.000000" in summary
    assert "median,2,11.000000,22.000000,11.000000,2.000000" in summary
    for invalid in (
        sample.replace("m3_delivery,1,raw_raster_lease,1000,12,0,4000\n", ""),
        sample.replace("m3_delivery,0,raw_raster_lease,1000,10,0,1000",
                       "m3_delivery,0,raw_raster_lease,0,10,0,1000"),
        sample.replace("DELIVERY-BENCH PASS: test\n", ""),
    ):
        try:
            summarize(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted incomplete/invalid timing evidence")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        print("DELIVERY SUMMARY SELF-TEST PASS")
    elif len(sys.argv) == 2:
        try:
            print(summarize(Path(sys.argv[1]).read_text()), end="")
        except (OSError, ValueError) as err:
            sys.exit(f"delivery summary invalid: {err}")
    else:
        sys.exit("Usage: summarize_m3_rgba_delivery_xps.py [--self-test|raw-runner.txt]")
