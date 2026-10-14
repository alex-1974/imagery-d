#!/usr/bin/env python3
"""Strict paired mixed cache workload verifier; source of XPS report rows.

No XPS timing claims from CI runner smoke, and no RSS inference from a
per-thread GC-allocation counter. The source/dependency provenance must
be verified against the evidence archive separately.
"""
import csv
import io
import statistics
import sys
from pathlib import Path

HEADER = ("experiment,side,hit_percent,subscribers,round,variant,"
          "requests,hits,misses,evictions,retains,refunds,elapsed_us,"
          "thread_gc_bytes,digest")
VARIANTS = {"raw", "controlled"}


def summarize(text: str) -> str:
    lines = text.splitlines()
    if lines.count(HEADER) != 1:
        raise ValueError("missing or duplicated mixed CSV header")
    if sum(line.startswith("DELIVERY-MIXED PASS:") for line in lines) != 1:
        raise ValueError("missing/duplicated mixed PASS trailer")
    source = [line for line in lines
              if line.startswith("m3_delivery_mixed,")]
    if not source:
        raise ValueError("mixed rows missing")
    parsed = csv.DictReader(io.StringIO(HEADER + "\n" +
                                        "\n".join(source)))
    groups: dict[tuple[int, int, int, int], dict[str, dict]] = {}
    profiles: dict[tuple[int, int, int], set[int]] = {}
    for row in parsed:
        if None in row or None in row.values():
            raise ValueError("malformed CSV field count")
        try:
            fields = {k: int(row[k]) for k in (
                "side", "hit_percent", "subscribers", "round",
                "requests", "hits", "misses", "evictions", "retains",
                "refunds", "elapsed_us", "thread_gc_bytes", "digest")}
        except (TypeError, ValueError, KeyError) as exc:
            raise ValueError("invalid numeric mixed row") from exc
        side, hit, subs, round_no = (
            fields["side"], fields["hit_percent"],
            fields["subscribers"], fields["round"])
        n = fields["requests"]
        if (row["experiment"] != "m3_delivery_mixed" or
                row["variant"] not in VARIANTS or
                side not in (16, 64) or hit not in (25, 75, 95) or
                subs not in (1, 2, 4) or round_no < 0 or
                n < 100 or n % 100 or fields["elapsed_us"] <= 0 or
                fields["thread_gc_bytes"] < 0 or fields["digest"] <= 0 or
                fields["hits"] != n * hit // 100 or
                fields["misses"] != n - fields["hits"] or
                fields["evictions"] != fields["misses"] or
                fields["refunds"] != fields["misses"] or
                fields["retains"] != n * subs + fields["misses"]):
            raise ValueError("invalid mixed trace counts or profile")
        key = (side, hit, subs, round_no)
        group = groups.setdefault(key, {})
        if row["variant"] in group:
            raise ValueError("duplicate variant for a round")
        group[row["variant"]] = fields
        profiles.setdefault((side, hit, subs), set()).add(round_no)

    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow([
        "record", "side", "hit_percent", "subscribers", "round",
        "requests", "hits", "misses", "raw_us_per_request",
        "controlled_us_per_request", "controlled_minus_raw_us",
        "controlled_over_raw_ratio", "raw_gc_bytes", "controlled_gc_bytes",
        "digest"
    ])
    for profile in sorted(profiles):
        rounds = sorted(profiles[profile])
        if rounds != list(range(len(rounds))):
            raise ValueError("round sequence missing or noncontiguous")
        raw_values, ctrl_values, diffs, ratios = [], [], [], []
        expected_n = None
        for round_no in rounds:
            raw_and_ctrl = groups[(profile[0], profile[1],
                                   profile[2], round_no)]
            if set(raw_and_ctrl) != VARIANTS:
                raise ValueError("unpaired raw/controlled stage")
            raw, ctrl = raw_and_ctrl["raw"], raw_and_ctrl["controlled"]
            for field in ("requests", "hits", "misses", "evictions",
                          "retains", "refunds", "digest"):
                if raw[field] != ctrl[field]:
                    raise ValueError("unequal paired work/pixel result")
            n = raw["requests"]
            if expected_n is None:
                expected_n = n
            elif expected_n != n:
                raise ValueError("changed sample count across rounds")
            raw_us = raw["elapsed_us"] / n
            ctrl_us = ctrl["elapsed_us"] / n
            diff = ctrl_us - raw_us
            ratio = ctrl_us / raw_us
            raw_values.append(raw_us)
            ctrl_values.append(ctrl_us)
            diffs.append(diff)
            ratios.append(ratio)
            writer.writerow([
                "round", *profile, round_no, n, raw["hits"],
                raw["misses"], f"{raw_us:.6f}", f"{ctrl_us:.6f}",
                f"{diff:.6f}", f"{ratio:.6f}",
                raw["thread_gc_bytes"], ctrl["thread_gc_bytes"],
                raw["digest"],
            ])
        writer.writerow([
            "median", *profile, len(rounds), expected_n,
            expected_n * profile[1] // 100,
            expected_n - expected_n * profile[1] // 100,
            f"{statistics.median(raw_values):.6f}",
            f"{statistics.median(ctrl_values):.6f}",
            f"{statistics.median(diffs):.6f}",
            f"{statistics.median(ratios):.6f}", "", "", "",
        ])
    return out.getvalue()


def self_test() -> None:
    rows = [HEADER]
    for round_no in range(2):
        for variant, microseconds, gc in (
            ("raw", 100, 0), ("controlled", 130, 128)
        ):
            rows.append(
                f"m3_delivery_mixed,16,75,2,{round_no},{variant},"
                f"100,75,25,25,225,25,{microseconds},"
                f"{gc},123456"
            )
    rows.append("DELIVERY-MIXED PASS: synthetic")
    src = "\n".join(rows) + "\n"
    result = summarize(src)
    assert "round,16,75,2,0,100,75,25,1.000000,1.300000" in result
    assert "median,16,75,2,2,100,75,25,1.000000,1.300000" in result
    for invalid in (
        src.replace("DELIVERY-MIXED PASS: synthetic\n", ""),
        src.replace("100,75,25,25,225,25,130,128,123456",
                    "100,75,25,25,225,25,130,128,123457"),
        src.replace("100,75,25,25,225,25,130,128,123456",
                    "100,75,25,24,225,25,130,128,123456"),
        src.replace("m3_delivery_mixed,16,75,2,1,controlled",
                    "m3_delivery_mixed,16,75,2,2,controlled"),
    ):
        try:
            summarize(invalid)
        except ValueError:
            continue
        raise AssertionError("accepted invalid mixed benchmark evidence")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        print("MIXED DELIVERY SUMMARY SELF-TEST PASS")
    elif len(sys.argv) == 2:
        try:
            print(summarize(Path(sys.argv[1]).read_text()), end="")
        except (OSError, ValueError) as exc:
            sys.exit(f"invalid mixed benchmark: {exc}")
    else:
        sys.exit("Usage: summarize_m3_rgba_delivery_mixed_xps.py [--self-test|runner.txt]")
