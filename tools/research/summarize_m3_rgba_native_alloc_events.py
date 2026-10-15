#!/usr/bin/env python3
"""Issue #74 single-thread glibc interposer event stream verification.

ONLY intercepted libc malloc/free/calloc/realloc/aligned calls made on the
instrumented D thread count. Requested sizes, not usable sizes or RSS.
Unknown mallocs are NOT automatically labeled raster-d control blocks.
"""
import csv
import io
import sys
from pathlib import Path

STAGES = tuple(range(1, 10))
PRODUCERS = (2, 4, 5)


def audit(events: str, side: int) -> dict:
    if side not in (16, 64, 256, 512):
        raise ValueError("unsupported ROI side")
    records = list(csv.reader(io.StringIO(events)))
    if not records:
        raise ValueError("empty allocation-event stream")
    live: dict[int, tuple[int, int, int]] = {}
    seen_stages = []
    intents = []
    tagged = []
    outstanding = peak = total = 0
    unknown_frees = 0
    other_allocs = other_bytes = 0
    allocation_count = free_count = 0
    intent_pending = None
    current = 0
    expected_stage = 1
    previous_action = ""
    for record in records:
        if len(record) != 5:
            raise ValueError("wrong number of allocation-event fields")
        action, raw_phase, raw_ptr, raw_bytes, raw_kind = record
        try:
            phase = int(raw_phase)
            ptr = int(raw_ptr, 16)
            size = int(raw_bytes)
            kind = int(raw_kind)
        except ValueError as exc:
            raise ValueError("bad native trace numeric field") from exc
        if size < 0 or kind not in (0, 1, 2) or phase not in STAGES:
            raise ValueError("impossible trace phase/size/kind")
        if action == "S":
            if phase != expected_stage or current or ptr or kind or size:
                raise ValueError("nonsequential/native phase start")
            current = phase
            seen_stages.append(phase)
            continue
        if action == "E":
            if phase != current or ptr or kind or size not in (0, phase+1):
                raise ValueError("nonsequential/native phase end")
            if intent_pending is not None:
                raise ValueError("unmatched payload intent")
            expected_stage = current + 1
            current = 0
            continue
        if current != phase:
            raise ValueError("allocation outside current phase")
        if action == "I":
            if ptr or size <= 0 or kind not in (1, 2) or (
                phase not in PRODUCERS or intent_pending is not None
            ):
                raise ValueError("invalid tagged explicit pixel allocation intent")
            intent_pending = (phase, size, kind)
            # Normalize the captured intent to (phase, kind, bytes),
            # preserving the pending matcher separately as (phase, bytes, kind).
            intents.append((phase, kind, size))
            previous_action = action
            continue
        if action == "A":
            if not ptr:
                raise ValueError("failed native allocation in successful trace")
            if ptr in live:
                raise ValueError("pointer allocated twice without release")
            if kind:
                if intent_pending != (phase, size, kind):
                    raise ValueError("tagged allocation without matching intent")
                tagged.append((phase, kind, size, ptr))
            elif intent_pending is not None:
                # Intent is always immediately followed by matching malloc
                # in the independent consumer's research-owned helper.
                raise ValueError("unexpected untagged allocation after intent")
            intent_pending = None
            live[ptr] = (size, kind, phase)
            outstanding += size
            peak = max(peak, outstanding)
            total += size
            allocation_count += 1
            if kind == 0:
                other_allocs += 1
                other_bytes += size
            previous_action = action
            continue
        if action == "F":
            if size or kind or not ptr:
                raise ValueError("bad free event")
            old = live.pop(ptr, None)
            if old is None:
                unknown_frees += 1   # Existing fixture/global owner.
            else:
                outstanding -= old[0]
            free_count += 1
            previous_action = action
            continue
        raise ValueError("unknown trace action")

    if current or seen_stages != list(STAGES):
        raise ValueError("missing final stage/terminal recorder stop")
    # The end marker for stage 9 signals a switch to disabled stage 0.
    payload = 4 * side * side
    expected = [(phase, kind, payload)
                for phase in PRODUCERS for kind in (1, 2)]
    if intents != expected or [(p,k,s) for p,k,s,_ in tagged] != expected:
        raise ValueError("expected exactly scratch+packed per A/B/C production")
    unfreed = [(p,k,sz,ptr) for p,k,sz,ptr in tagged if ptr in live]
    # Check frees by physical allocation ID, not arena/RSS delta.
    if unfreed:
        raise ValueError(f"true packed/scratch pointers remain live: {len(unfreed)}")
    if outstanding < 0:
        raise ValueError("negative outstanding requested allocation sum")
    return {
        "side": side,
        "tagged_pixel_allocations": len(tagged),
        "requested_pixel_bytes": sum(x[2] for x in tagged),
        "tagged_pixel_bytes_max_at_once": max(
            _tagged_live_peak(records), 0),
        "other_intercepted_malloc_calls": other_allocs,
        "other_intercepted_requested_bytes_total": other_bytes,
        "intercepted_allocation_events": allocation_count,
        "intercepted_free_events": free_count,
        "unmatched_pretrace_free_events": unknown_frees,
        "intercepted_requested_bytes_peak": peak,
        "intercepted_requested_bytes_final_live": outstanding,
    }


def _tagged_live_peak(records):
    live = {}
    peak = n = 0
    for action, phase, raw_ptr, size, kind in records:
        ptr = int(raw_ptr, 16)
        if action == "A":
            live[ptr] = (int(size), int(kind))
            if int(kind):
                n += int(size)
                peak = max(peak, n)
        elif action == "F":
            old = live.pop(ptr, None)
            if old and old[1]:
                n -= old[0]
    return peak


def self_test():
    payload = 1024
    rows = []
    for stage in STAGES:
        rows.append(f"S,{stage},0x0,0,0")
        if stage in PRODUCERS:
            for kind in (1, 2):
                ptr = (stage * 10 + kind)
                rows.append(f"I,{stage},0x0,{payload},{kind}")
                rows.append(f"A,{stage},0x{ptr:x},{payload},{kind}")
            rows.append(f"F,{stage},0x{stage*10+1:x},0,0")
        if stage in (7,8,9):
            first = PRODUCERS[stage - 7]
            rows.append(f"F,{stage},0x{first*10+2:x},0,0")
        rows.append(f"E,{stage},0x0,{stage+1 if stage<9 else 0},0")
    trace = "\n".join(rows) + "\n"
    result = audit(trace, 16)
    assert result["tagged_pixel_allocations"] == 6
    assert result["intercepted_requested_bytes_final_live"] == 0
    assert result["tagged_pixel_bytes_max_at_once"] == 4096
    for corrupt in (
        trace.replace("I,2,0x0,1024,1", "I,2,0x0,1023,1"),
        trace.replace("F,9,0x34,0,0", ""),  # Missing last packed owner.
        trace.replace("S,5,0x0,0,0", "S,4,0x0,0,0"),
        trace.replace("A,4,0x29,1024,1", "A,4,0x29,1024,0"),
    ):
        try:
            audit(corrupt, 16)
        except ValueError:
            continue
        raise AssertionError("accepted invalid native allocation evidence")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        print("NATIVE ALLOCATION EVENT VALIDATOR SELF-TEST PASS")
        return
    if len(sys.argv) != 3:
        sys.exit("Usage: summarize_m3_rgba_native_alloc_events.py [--self-test|events.csv SIDE]")
    try:
        result = audit(Path(sys.argv[1]).read_text(), int(sys.argv[2]))
    except (ValueError, OSError) as exc:
        sys.exit(f"invalid allocation event evidence: {exc}")
    writer = csv.DictWriter(sys.stdout, fieldnames=tuple(result))
    writer.writeheader()
    writer.writerow(result)


if __name__ == "__main__":
    main()
