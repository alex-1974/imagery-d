#!/usr/bin/env python3
"""Compare matched Linux/glibc interception controls for imagery-d Issue #74.

The four cases differ in native *research consumer* activity:
markers = metadata+sampler only; raw = 3 malloc pairs; import =
public raster-d adoption/lease; full = actual RGBA source-over.
Events are one-thread intercepted requests, NOT full native/RSS bounds.
"""
from __future__ import annotations

import csv
import io
import sys
from pathlib import Path

STAGES = (1, 2, 3, 4, 5, 6, 7, 8, 9)
PRODUCERS = (2, 4, 5)
CASES = ("markers", "raw", "import", "full")
SIDE = (16, 64, 256, 512)


def validate(trace: str, case: str, side: int) -> list[dict]:
    if case not in CASES or side not in SIDE:
        raise ValueError("unrecognized case or ROI side")
    samples = list(csv.reader(io.StringIO(trace)))
    if not samples:
        raise ValueError("empty native event trace")
    size = 4 * side * side
    current = 0
    expected = 1
    live = {}  # ptr: (requested, kind, originating_stage)
    tracked = {}  # kind 2 packed backing: stage producer -> ptr
    intent = None
    all_tagged = []
    rows = []
    cumulative_total = 0
    cumulative_other = 0
    total_peak = 0
    other_count_total = 0
    unknown_frees_total = 0
    for sample in samples:
        if len(sample) != 5:
            raise ValueError("malformed allocation-event row")
        action, phase_raw, pointer_raw, bytes_raw, kind_raw = sample
        try:
            phase, ptr, amount, kind = (
                int(phase_raw), int(pointer_raw, 16),
                int(bytes_raw), int(kind_raw)
            )
        except ValueError as exc:
            raise ValueError("invalid event field") from exc
        if (phase not in STAGES or amount < 0 or
                kind not in (0, 1, 2)):
            raise ValueError("bad stage/requested bytes/kind")
        if action == "S":
            if (phase != expected or current or ptr or amount or
                    kind or intent is not None):
                raise ValueError("missing/reordered stage start")
            current = phase
            row = dict(case=case, side=side, stage=phase,
                       tagged_malloc_calls=0, tagged_requested_bytes=0,
                       other_malloc_calls=0, other_requested_bytes=0,
                       tagged_free_calls=0, other_free_calls=0,
                       pretrace_free_calls=0,
                       peak_intercepted_requested_bytes=0,
                       end_live_tagged_bytes=0,
                       end_live_other_bytes=0)
            continue
        if action == "E":
            if (phase != current or ptr or kind or
                    amount != (phase + 1 if phase < 9 else 0) or
                    intent is not None):
                raise ValueError("wrong end-stage marker or dangling intent")
            row["end_live_tagged_bytes"] = sum(v[0] for v in live.values()
                                                  if v[1] != 0)
            row["end_live_other_bytes"] = sum(v[0] for v in live.values()
                                                 if v[1] == 0)
            rows.append(row)
            current = 0
            expected += 1
            continue
        if current != phase or current == 0:
            raise ValueError("native event outside controlled phase")
        if action == "I":
            if (case == "markers" or phase not in PRODUCERS or
                ptr or amount != size or kind not in (1, 2) or
                intent is not None):
                raise ValueError("unexpected tagged allocation intent")
            intent = (phase, amount, kind)
            continue
        if action == "A":
            if ptr == 0 or ptr in live:
                raise ValueError("null or duplicate malloc pointer")
            if intent is not None and intent != (phase, amount, kind):
                raise ValueError("tag/size mismatch after allocation intent")
            if intent is None and kind:
                raise ValueError("tagged malloc without declared intent")
            if kind:
                if phase not in PRODUCERS or amount != size:
                    raise ValueError("tagged pixels outside real producer")
                all_tagged.append((phase, kind, ptr))
                row["tagged_malloc_calls"] += 1
                row["tagged_requested_bytes"] += amount
                if kind == 2:
                    if phase in tracked:
                        raise ValueError("two packed backings in one stage")
                    tracked[phase] = ptr
            else:
                row["other_malloc_calls"] += 1
                row["other_requested_bytes"] += amount
                other_count_total += 1
                cumulative_other += amount
            intent = None
            live[ptr] = (amount, kind, phase)
            cumulative_total += amount
            total_peak = max(total_peak, cumulative_total)
            row["peak_intercepted_requested_bytes"] = max(
                row["peak_intercepted_requested_bytes"], cumulative_total)
            continue
        if action == "F":
            if ptr == 0 or amount or kind:
                raise ValueError("malformed free")
            old = live.pop(ptr, None)
            if old is None:
                row["pretrace_free_calls"] += 1
                unknown_frees_total += 1
            else:
                cumulative_total -= old[0]
                if old[1]:
                    row["tagged_free_calls"] += 1
                    if old[1] == 1 and phase != old[2]:
                        raise ValueError("four-channel scratch outlived producer")
                    if old[1] == 2:
                        finish_stage = {2: 7, 4: 8, 5: 9}[old[2]]
                        if phase != finish_stage:
                            raise ValueError("packed buffer released too early/late")
                else:
                    row["other_free_calls"] += 1
            continue
        raise ValueError("unknown allocation operation")

    if current or expected != 10 or len(rows) != 9 or intent is not None:
        raise ValueError("incomplete nine-stage native ownership trace")
    wanted = [] if case == "markers" else [
        (stage, kind) for stage in PRODUCERS for kind in (1, 2)
    ]
    if [(p, k) for p,k,_ in all_tagged] != wanted:
        raise ValueError("not exactly the expected A/B/C tagged allocations")
    if any(k for _,k,_ in live.values()):
        raise ValueError("tagged pixel pointers not all physically freed")
    if cumulative_total != sum(z[0] for z in live.values()):
        raise ValueError("inconsistent requested-byte ledger")
    if rows[-1]["end_live_tagged_bytes"] != 0:
        raise ValueError("tagged bytes remain after final close")
    if sum(r["other_malloc_calls"] for r in rows) != other_count_total:
        raise ValueError("unclassified call count drift")
    return rows


def summarize(trace: str, case: str, side: int) -> dict:
    rows = validate(trace, case, side)
    return {
        "case": case, "side": side,
        "tagged_allocations": sum(r["tagged_malloc_calls"] for r in rows),
        "tagged_requested_bytes": sum(r["tagged_requested_bytes"] for r in rows),
        "other_malloc_calls": sum(r["other_malloc_calls"] for r in rows),
        "other_requested_bytes": sum(r["other_requested_bytes"] for r in rows),
        "other_requested_bytes_stage1": rows[0]["other_requested_bytes"],
        "other_requested_bytes_producers": sum(rows[i-1]["other_requested_bytes"]
                                                for i in PRODUCERS),
        "other_end_live_bytes": rows[-1]["end_live_other_bytes"],
        "peak_intercepted_requested_bytes": max(
            r["peak_intercepted_requested_bytes"] for r in rows),
        "unknown_pretrace_frees": sum(r["pretrace_free_calls"] for r in rows),
    }


def self_test() -> None:
    for case in CASES:
        trace = []
        for phase in STAGES:
            trace.append(f"S,{phase},0x0,0,0")
            if phase in PRODUCERS and case != "markers":
                for kind in (1, 2):
                    ptr = phase * 10 + kind
                    trace.append(f"I,{phase},0x0,1024,{kind}")
                    trace.append(f"A,{phase},0x{ptr:x},1024,{kind}")
                trace.append(f"F,{phase},0x{phase*10+1:x},0,0")
            if phase in (7,8,9) and case != "markers":
                originating = {7:2,8:4,9:5}[phase]
                trace.append(f"F,{phase},0x{originating*10+2:x},0,0")
            trace.append(f"E,{phase},0x0,{phase+1 if phase<9 else 0},0")
        content = "\n".join(trace) + "\n"
        s = summarize(content, case, 16)
        assert s["tagged_allocations"] == (0 if case == "markers" else 6)
        if case == "markers":
            assert s["peak_intercepted_requested_bytes"] == 0
        for damaged in (
            content.replace("S,5,0x0,0,0", "S,4,0x0,0,0"),
            content.replace("E,9,0x0,0,0", ""),
            content.replace("F,9,0x34,0,0", "") if case != "markers"
                else content.replace("E,1,0x0,2,0", ""),
        ):
            try:
                validate(damaged, case, 16)
            except ValueError:
                continue
            raise AssertionError("accepted malformed control trace")
    print("NATIVE ALLOCATION CONTROLS SELF-TEST PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 5:
        sys.exit("Usage: summarize_m3_rgba_native_alloc_controls.py EVENTS.csv CASE SIDE OUTPUT_PREFIX")
    try:
        rows = validate(Path(sys.argv[1]).read_text(), sys.argv[2], int(sys.argv[3]))
        summary = summarize(Path(sys.argv[1]).read_text(), sys.argv[2], int(sys.argv[3]))
    except (ValueError, OSError) as exc:
        sys.exit(f"invalid native allocation control: {exc}")
    prefix = Path(sys.argv[4])
    with prefix.with_name(prefix.name + "-stages.csv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=tuple(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with prefix.with_name(prefix.name + "-summary.csv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=tuple(summary))
        writer.writeheader()
        writer.writerow(summary)


if __name__ == "__main__":
    main()
