#!/usr/bin/env python3
"""Strict replay of Issue #74 real 1-vs-4 subscriber, three-backing snapshots.

Linux /proc, glibc mallinfo2 and thread GC counters are observations, NOT
physical per-subscriber costs or composable memory budget terms.
"""
import csv
import io
import sys
from pathlib import Path

FIELDS = (
    "experiment", "side", "subscribers_per_generation", "phase",
    "active_generations", "live_subscribers",
    "requested_live_payload_bytes", "illustrative_charge_bytes",
    "thread_gc_cumulative_bytes", "glibc_malloc_used_bytes",
    "glibc_mmap_bytes", "glibc_free_bytes", "vmrss_kib", "vmhwm_kib"
)
HEADER = ",".join(FIELDS)
PHASES = (
    "fixtures", "accounting", "a_live", "a_evicted", "ab_live",
    "abc_live", "cache_exited", "extras_closed", "a_closed",
    "b_closed", "c_closed"
)
ACTIVE = (0, 0, 1, 1, 2, 3, 3, 3, 2, 1, 0)


def validate(source):
    lines = source.splitlines()
    if lines.count(HEADER) != 1:
        raise ValueError("expected one exact snapshot header")
    data = [line for line in lines
            if line.startswith("m3_generation_subscriber_memory,")]
    if len(data) != len(PHASES):
        raise ValueError("unexpected snapshot row count")
    trailers = [line for line in lines
                if line.startswith("M3 GENERATION SUBSCRIBER MEMORY PASS:")]
    if len(trailers) != 1:
        raise ValueError("expected one success receipt")
    reader = csv.DictReader(io.StringIO(HEADER + "\n" +
                                       "\n".join(data)))
    rows = list(reader)
    if reader.fieldnames != list(FIELDS) or len(rows) != len(PHASES):
        raise ValueError("invalid columns")
    if any(set(row) != set(FIELDS) or
           None in row or None in row.values() for row in rows):
        raise ValueError("malformed CSV fields")
    numeric = [key for key in FIELDS if key not in ("experiment", "phase")]
    try:
        for row in rows:
            for key in numeric:
                if not row[key].isdigit():
                    raise ValueError(f"noncanonical integer for {key}")
                row[key] = int(row[key])
    except (TypeError, AttributeError, ValueError) as exc:
        raise ValueError("invalid numeric field") from exc
    side = rows[0]["side"]
    subs = rows[0]["subscribers_per_generation"]
    if side not in (16, 64, 256, 512) or subs not in (1, 4):
        raise ValueError("unsupported experimental parameters")
    if trailers[0] != (
        f"M3 GENERATION SUBSCRIBER MEMORY PASS: side={side} "
        f"subscribers={subs} three real generations; "
        "zero final retained charges"
    ):
        raise ValueError("receipt does not match experiment")
    requested = 4 * side * side
    for i, row in enumerate(rows):
        live = ACTIVE[i]
        expected_subs = (
            0 if i < 2 else
            live * subs if i < 7 else
            3 if i == 7 else live
        )
        if (
            row["experiment"] != "m3_generation_subscriber_memory" or
            row["side"] != side or
            row["subscribers_per_generation"] != subs or
            row["phase"] != PHASES[i] or
            row["active_generations"] != live or
            row["live_subscribers"] != expected_subs or
            row["requested_live_payload_bytes"] != live * requested or
            row["illustrative_charge_bytes"] != live * (requested + 64)
        ):
            raise ValueError(f"wrong phase/owner/payload accounting: {PHASES[i]}")
        if any(row[key] < 0 for key in numeric):
            raise ValueError("negative observed memory metric")
        if row["vmhwm_kib"] < row["vmrss_kib"]:
            raise ValueError("sample VmHWM < VmRSS")
        if i and row["thread_gc_cumulative_bytes"] < (
            rows[i-1]["thread_gc_cumulative_bytes"]
        ):
            raise ValueError("GC cumulative counter regressed")
    if rows[1]["thread_gc_cumulative_bytes"] <= (
        rows[0]["thread_gc_cumulative_bytes"]
    ):
        raise ValueError("no GC control-class allocation")
    return rows


def synthetic(subscribers=4, side=16):
    data = [HEADER]
    for i, phase in enumerate(PHASES):
        n = ACTIVE[i]
        k = 0 if i < 2 else n*subscribers if i < 7 else (
            3 if i == 7 else n)
        rss = 1000 + n * 16
        data.append(
            f"m3_generation_subscriber_memory,{side},{subscribers},"
            f"{phase},{n},{k},{n*4*side*side},"
            f"{n*(4*side*side+64)},{256 if i else 0},"
            f"{12000+n*4*side*side},0,4000,{rss},"
            f"{1000+max(ACTIVE[:i+1])*16}"
        )
    data.append(f"M3 GENERATION SUBSCRIBER MEMORY PASS: side={side} "
                f"subscribers={subscribers} three real generations; "
                "zero final retained charges")
    return "\n".join(data) + "\n"


def self_test():
    for subs in (1, 4):
        for side in (16, 512):
            assert len(validate(synthetic(subs, side))) == 11
    reference = synthetic()
    broken = [
        reference.replace(",12,3072,", ",11,3072,"),
        reference.replace("a_evicted,1,4,", "a_evicted,0,0,"),
        reference.replace("extras_closed,3,3,", "extras_closed,3,12,"),
        reference.replace("c_closed,0,0,0,0,", "c_closed,1,1,1024,1088,"),
        reference.replace("M3 GENERATION SUBSCRIBER MEMORY PASS:",
                          "BROKEN SUBSCRIBER PASS:"),
        reference.replace(",1024,1088,256,", ",1024,1087,256,"),
    ]
    for corrupted in broken:
        if corrupted == reference:
            raise AssertionError("negative fixture mutation had no effect")
        try:
            validate(corrupted)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted broken independent snapshot trace")
    print("GENERATION SUBSCRIBER MEMORY VALIDATOR SELF-TEST PASS")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 2:
        rows = validate(Path(sys.argv[1]).read_text(encoding="utf-8"))
        writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    else:
        sys.exit("usage: subscriber-memory-validator.py [--self-test|trace.txt]")


if __name__ == "__main__":
    main()
